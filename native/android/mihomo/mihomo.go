package mihomo

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"runtime/debug"
	"strings"
	"sync"
	"syscall"

	"github.com/metacubex/mihomo/component/dialer"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
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

func Setup(homeDir string) {
	C.SetHomeDir(homeDir)

	// cmfa 标签会把控制面默认切成 embed 模式，连 PATCH /configs 一起摘掉
	route.SetEmbedMode(false)

	// 与界面同进程；Go 默认 GC 太晚，规则集一多就被 LMK 杀掉
	debug.SetGCPercent(10)
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

func Check(configJSON string) error {
	if _, err := executor.ParseWithBytes([]byte(configJSON)); err != nil {
		return trimmed(err)
	}
	return nil
}

// tunFd≤0 表示不接 TUN。换 VPN 参数须重新 establish 再调本函数；面板 proxies/rules 热载用 Reload
func Start(configJSON string, tunFd int32) error {
	cfg, err := executor.ParseWithBytes([]byte(configJSON))
	if err != nil {
		return trimmed(err)
	}
	bindTun(&cfg.General.Tun, configJSON, int(tunFd))

	mu.Lock()
	defer mu.Unlock()
	hub.ApplyConfig(cfg)
	running = true
	return ensureTunBound(cfg.General.Tun.Enable)
}

// Dart 侧 PUT /configs 带不上 fd，面板配置热载必须走这里
func Reload(configJSON string) error {
	cfg, err := executor.ParseWithBytes([]byte(configJSON))
	if err != nil {
		return trimmed(err)
	}

	mu.Lock()
	defer mu.Unlock()
	if !running {
		return errors.New("内核未运行")
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
