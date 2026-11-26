package mihomo

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"runtime/debug"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"go4.org/netipx"
)

// 不 protect 的话出站会被自己建的 TUN 再吸一遍，直接成环
type Protector interface {
	Protect(fd int32) bool
}

var (
	mu      sync.Mutex
	running bool
)

const controllerTimeout = 10 * time.Second

var errControllerNotReady = fmt.Errorf("内核控制面在 %d 秒内未就绪", int(controllerTimeout/time.Second))

func Setup(homeDir string) {
	C.SetHomeDir(homeDir)

	// cmfa 标签会把控制面默认切成 embed 模式，连 PATCH /configs 一起摘掉
	route.SetEmbedMode(false)

	// 与界面同进程；Go 默认 GC 太晚，规则集一多就被 LMK 杀掉
	debug.SetGCPercent(10)

	// 其它 goroutine 的 panic 与 fatal error 只进 logcat，用户导出的应用日志里没有；
	// 留在文件里，由界面进程在 :kernel 死掉后转述（KernelClient.crashCause）
	if file, err := os.Create(filepath.Join(homeDir, "kernel-crash.log")); err == nil {
		_ = debug.SetCrashOutput(file, debug.CrashOptions{})
		_ = file.Close()
	}
}

// 内核在 DefaultSocketHook 非空时会忽略 interface-name / routing-mark
func SetProtector(p Protector) {
	if p == nil {
		dialer.DefaultSocketHook = nil
		return
	}

	dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
		var refused error
		if err := conn.Control(func(fd uintptr) {
			if !p.Protect(int32(fd)) {
				refused = errors.New("VpnService.protect 拒绝了内核出站 socket")
			}
		}); err != nil {
			return err
		}
		return refused
	}
}

// gomobile 导出函数里的 panic 会直接带崩 :kernel 进程；配置已先落盘，系统重建服务后会反复崩溃
func recoverAsError(err *error, cleanup func()) {
	if r := recover(); r != nil {
		if cleanup != nil {
			cleanup()
		}
		*err = fmt.Errorf("内核处理配置时异常: %v", r)
	}
}

func Check(configJSON string) (err error) {
	mu.Lock()
	defer mu.Unlock()
	defer recoverAsError(&err, nil)
	if _, err := executor.ParseWithBytes([]byte(configJSON)); err != nil {
		return trimmed(err)
	}
	return nil
}

// tunFd≤0 表示不接 TUN。Fake-IP 更新须先保存地址池再解析，不能走 Reload。
func Start(configJSON string, tunFd int32) (err error) {
	mu.Lock()
	defer mu.Unlock()
	defer recoverAsError(&err, stopLocked)
	stopLocked()

	cfg, err := executor.ParseWithBytes([]byte(configJSON))
	if err != nil {
		if tunFd > 0 {
			_ = os.NewFile(uintptr(tunFd), "tun").Close()
		}
		return trimmed(err)
	}
	bindTun(&cfg.General.Tun, configJSON, int(tunFd))

	controller := watchController(cfg.Controller.ExternalController)
	hub.ApplyConfig(cfg)
	running = true
	if err := <-controller; err != nil {
		stopLocked()
		return err
	}
	return ensureTunBound(cfg.General.Tun.Enable)
}

// 端口在 Dart 选定之后、内核监听之前可能被同机其它应用抢先占住：内核只记一行日志照常运行，
// 带 secret 的控制面请求就会交给对方。订阅者积压会阻塞全部日志，退订完成前必须一直读空
func watchController(address string) <-chan error {
	result := make(chan error, 1)
	if address == "" {
		result <- nil
		return result
	}
	events := log.Subscribe()
	go func() {
		result <- controllerEvent(events, address)
		go log.UnSubscribe(events)
		for range events {
		}
	}()
	return result
}

func controllerEvent(events <-chan log.Event, address string) error {
	timeout := time.NewTimer(controllerTimeout)
	defer timeout.Stop()
	for {
		select {
		case event, ok := <-events:
			if !ok {
				return errControllerNotReady
			}
			if event.Payload == "RESTful API listening at: "+address {
				return nil
			}
			if strings.HasPrefix(event.Payload, "External controller listen error") {
				return fmt.Errorf("控制面端口 %s 已被其它程序占用，请重新连接", portOf(address))
			}
		case <-timeout.C:
			return errControllerNotReady
		}
	}
}

func portOf(address string) string {
	if _, port, err := net.SplitHostPort(address); err == nil {
		return port
	}
	return address
}

// Dart 侧 PUT /configs 带不上 fd，非 Fake-IP 配置热载在此保留 fd。
func Reload(configJSON string) (err error) {
	mu.Lock()
	defer mu.Unlock()
	defer recoverAsError(&err, stopLocked)
	if !running {
		return errors.New("内核未运行")
	}
	cfg, err := executor.ParseWithBytes([]byte(configJSON))
	if err != nil {
		return trimmed(err)
	}

	bindTun(&cfg.General.Tun, configJSON, listener.GetTunConf().FileDescriptor)
	executor.ApplyConfig(cfg, true)
	return ensureTunBound(cfg.General.Tun.Enable)
}

// parseTun 忽略配置里的 inet4-address，改用 fake-ip-range 截 /30；
// VpnService 按配置原文配址，FileDescriptor 形态下两边必须一致
func bindTun(tun *LC.Tun, configJSON string, tunFd int) {
	tun.Enable = tunFd > 0
	tun.FileDescriptor = tunFd
	tun.AutoRoute = false
	tun.AutoDetectInterface = false
	tun.StrictRoute = false
	if tunFd > 0 {
		if prefixes := inet4FromConfig(configJSON); len(prefixes) > 0 {
			tun.Inet4Address = prefixes
		}
	}
}

// ReCreateTun 失败只打 ERROR 并把 tun.enable 抹成 false，ApplyConfig 不报错
func ensureTunBound(want bool) error {
	if want && !listener.GetTunConf().Enable {
		return errors.New("内核未能接管 TUN，详见内核日志")
	}
	return nil
}

func inet4FromConfig(configJSON string) []netip.Prefix {
	var raw struct {
		Tun struct {
			Inet4 []string `json:"inet4-address"`
		} `json:"tun"`
	}
	if err := json.Unmarshal([]byte(configJSON), &raw); err != nil {
		return nil
	}
	prefixes := make([]netip.Prefix, 0, len(raw.Tun.Inet4))
	for _, text := range raw.Tun.Inet4 {
		prefix, err := netip.ParsePrefix(text)
		if err != nil {
			continue
		}
		prefixes = append(prefixes, prefix)
	}
	return prefixes
}

func Stop() {
	mu.Lock()
	defer mu.Unlock()
	stopLocked()
}

func stopLocked() {
	if !running {
		return
	}
	// Shutdown 不动 LastTunConf；下次 fd 号可能相同，ReCreateTun 会当成「没变」直接返回
	listener.ReCreateTun(LC.Tun{}, tunnel.Tunnel)
	executor.Shutdown()
	running = false
}

// 由 build-libmihomo.sh 用 ldflags 打进 constant.Version，须与 kernel.lock.json 一致
func Version() string {
	return C.Version
}

// nameserver-policy 里的 system 在 cmfa 构建下只认这里交进来的地址（dns/patch_android.go）。Kotlin 侧盯住能上网的
// 非 VPN 网络，换网时重设，内核不必重载；TUN 自己的 DNS 地址内核已拉黑，不会绕回
func SetSystemDNS(servers string) {
	updateSystemDNS(systemDNSServers(servers))
}

// Android 的 InetAddress.getHostAddress 给链路本地 IPv6 带 %网卡 作用域，netip 原样保留
func systemDNSServers(servers string) []string {
	var list []string
	for _, field := range strings.Fields(servers) {
		addr, err := netip.ParseAddr(field)
		if err != nil {
			continue
		}
		server := net.JoinHostPort(addr.String(), "53")
		if !slices.Contains(list, server) {
			list = append(list, server)
		}
	}
	return list
}

// route-exclude-address 落不到内核；excludeRoute 要 API 33，minSdk 24 覆盖不到，一律走补集
func RouteRanges(excluded string) (string, error) {
	var builder netipx.IPSetBuilder
	builder.AddPrefix(netip.PrefixFrom(netip.IPv4Unspecified(), 0))
	builder.AddPrefix(netip.PrefixFrom(netip.IPv6Unspecified(), 0))

	for _, line := range strings.Split(excluded, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		prefix, err := netip.ParsePrefix(line)
		if err != nil {
			return "", fmt.Errorf("route-exclude-address %q 不是合法网段", line)
		}
		builder.RemovePrefix(prefix)
	}

	set, err := builder.IPSet()
	if err != nil {
		return "", err
	}

	ranges := make([]string, 0, 32)
	for _, prefix := range set.Prefixes() {
		ranges = append(ranges, prefix.String())
	}
	return strings.Join(ranges, "\n"), nil
}

// 内核的解析错误常带多行上下文，界面只放得下一行
func trimmed(err error) error {
	text := strings.TrimSpace(err.Error())
	if index := strings.IndexByte(text, '\n'); index >= 0 {
		text = strings.TrimSpace(text[:index])
	}
	return errors.New(text)
}
