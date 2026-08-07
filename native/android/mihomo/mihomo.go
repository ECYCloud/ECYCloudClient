// Package mihomo 是 Android 侧的内核封装，供 gomobile bind 生成 libmihomo.aar。
//
// 只暴露启停、热载、配置校验、TUN 交接与版本查询：分应用名单、通知、开机自启等仍在
// Kotlin 侧。内核以依赖方式 import，不改一行内核代码。
//
// 控制面不在这里另开一套：配置里的 external-controller 与 secret 由 hub.ApplyConfig
// 拉起 Clash RESTful API，Dart 侧照桌面端那样直接连它。
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

// Protector 由 Kotlin 侧实现，把内核出站的 socket 交给 VpnService.protect(fd)。
// 不 protect 的话出站会被自己建的 TUN 再吸一遍，直接成环。
type Protector interface {
	Protect(fd int32) bool
}

var (
	mu      sync.Mutex
	running bool
)

// Setup 指定内核的工作目录：cache.db、geodata 与 rule-providers 的 path 都落在这里。
// 必须在 Start / Check 之前调用一次。
func Setup(homeDir string) {
	C.SetHomeDir(homeDir)

	// cmfa 标签会把控制面默认切成 embed 模式（hub/route/patch_android.go），连
	// PATCH /configs 一起摘掉，界面切换分流模式就会拿到 404。本客户端的控制面只
	// 监听回环、带随机 secret 且收紧了 CORS，按桌面端同一套端点开着即可
	route.SetEmbedMode(false)

	// 内核与界面同进程，Go 默认攒到上次存活堆的两倍才回收，安卓按整个进程的占用
	// 决定杀谁，规则集一多就先被杀。换更频繁的 GC 保命
	debug.SetGCPercent(10)
}

// SetProtector 装上 protect 回调。传 nil 表示摘掉。
//
// 内核在 DefaultSocketHook 非空时会忽略 interface-name / routing-mark，
// 这正是 Android 要的：出站走哪张网卡由系统决定，客户端只负责让它绕开 TUN。
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

// Check 只解析配置，不启动任何东西，对应桌面端的 mihomo -t。
func Check(configJSON string) error {
	if _, err := executor.ParseWithBytes([]byte(configJSON)); err != nil {
		return trimmed(err)
	}
	return nil
}

// Start 装载配置并启动内核。tunFd 是 VpnService.Builder.establish() 拿到的描述符，
// 传 0 或负数表示这次不接 TUN。
//
// 本地开关变更等需要换 VPN 参数时，Kotlin 侧会重新 establish 再调本函数：
// hub.ApplyConfig 会重建控制面并按新 fd 接管 TUN。面板 proxies/rules 热载请用 Reload。
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

// Reload 热载配置：保留当前 VpnService 已交接的 TUN fd，走 executor.ApplyConfig
// （与桌面 PUT /configs 同路），不重建 external-controller、不换 fd、不碰 VpnService。
// Dart 侧 PUT 带不上 fd，故面板配置热载必须走这里而非 Clash API。
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

// 路由、地址、DNS 与分应用名单都由 VpnService.Builder 定好了，内核只接管这个 fd：
// auto-route 会让内核自己去动系统路由表（Android 上没有权限也没有必要），
// auto-detect-interface 的活已经由 protect 回调顶掉了。
// parseTun 忽略配置里的 inet4-address，改用 fake-ip-range 截 /30；VpnService
// 按配置原文配址，FileDescriptor 形态下两边必须一致，否则 mixed 栈 Listen 失败。
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

// 内核起 TUN 监听器失败时只打一行 ERROR 就把 tun.enable 抹成 false 后照常返回
// （listener/listener.go 的 ReCreateTun），ApplyConfig 不会报错。这一路必须炸出来：
// VpnService 那张网卡已经建好，没人读它的 fd 就是所有流量掉进黑洞，而界面显示已连接。
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

// Stop 停内核。可重复调用。
func Stop() {
	mu.Lock()
	defer mu.Unlock()
	if !running {
		return
	}
	// executor.Shutdown 只关掉 TUN 监听器，不动 listener.LastTunConf，两者从此不一致。
	// 下一次 Start 拿到的 fd 号完全可能与上次相同（旧的两个号刚被 close，内核分配最小
	// 空闲号），ReCreateTun 就会把它判成「配置没变」直接返回，监听器再也建不起来：
	// 隧道彻底不通却连一行错误日志都没有。先按空配置过一遍，把这份残留一起复位
	listener.ReCreateTun(LC.Tun{}, tunnel.Tunnel)
	executor.Shutdown()
	running = false
}

// Version 报内核版本。取值由 build-libmihomo.sh 用 ldflags 打进 constant.Version，
// 与 kernel.lock.json 锁的 tag 一致；桌面端那边是 `mihomo -v` 的同一个值。
func Version() string {
	return C.Version
}

// RouteRanges 把 excluded 里的网段从 IPv4 与 IPv6 全域中挖掉，返回剩下的可路由前缀。
// 出入参都是换行分隔的 CIDR。
//
// 配置里的 route-exclude-address 在 Android 上落不到内核：TUN 由 VpnService 建，
// 排除段只能翻成 Builder.addRoute 的补集。Builder.excludeRoute 要 API 33，minSdk 24
// 覆盖不到，因此不分版本一律走补集。
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
