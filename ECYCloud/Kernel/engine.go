package kernel

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"runtime/debug"
	"sync"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener/sing"
	singtun "github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
	tun "github.com/metacubex/sing-tun"
)

const MaximumConfigBytes = 8 * 1024 * 1024
const MaximumPacketBytes = 65535

var ErrConfiguration = errors.New("内核配置无效或包含扩展不支持的监听器")
var ErrStopped = errors.New("连接已停止")
var ErrPacket = errors.New("数据包格式无效")
var ErrBusy = errors.New("内核正在运行")
var ErrQueueFull = errors.New("数据包队列已满")

// mihomo has process-wide state; each app or extension process owns one engine.
var lifecycle sync.Mutex
var currentMu sync.RWMutex
var current *instance
var nextID uint64

func init() { log.SetLevel(log.SILENT) }

type instance struct {
	id           uint64
	device       *packetDevice
	stack        tun.Stack
	cancel       context.CancelFunc
	logs         *logBuffer
	history      connectionHistory
	context      context.Context
	probes       map[string]*liveProbe
	probeWorkers sync.WaitGroup
	directory    string
	rules        map[string]string
	geoMu        sync.Mutex
	geoRunning   bool
	geoFailed    bool
}
type packetDevice struct {
	input, output chan []byte
	done          chan struct{}
	once          sync.Once
	mtu           int
}

func (p *packetDevice) Read(b []byte) (int, error) {
	select {
	case <-p.done:
		return 0, io.EOF
	case data := <-p.input:
		if len(data) > len(b) {
			return 0, io.ErrShortBuffer
		}
		return copy(b, data), nil
	}
}
func (p *packetDevice) Write(b []byte) (int, error) {
	if len(b) > MaximumPacketBytes {
		return 0, ErrPacket
	}
	select {
	case <-p.done:
		return 0, io.ErrClosedPipe
	case p.output <- append([]byte(nil), b...):
		return len(b), nil
	}
}
func (p *packetDevice) Close() error { p.once.Do(func() { close(p.done) }); return nil }

func device(id uint64) *packetDevice {
	currentMu.RLock()
	defer currentMu.RUnlock()
	if current == nil || current.id != id {
		return nil
	}
	return current.device
}

func Start(data []byte, directory string, mtu int, ipv4, ipv6, dnsAddress string) (uint64, error) {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if current != nil {
		return 0, ErrBusy
	}
	standby := mtu == 0 && ipv4 == "" && ipv6 == "" && dnsAddress == ""
	if (!standby && (mtu < 1280 || mtu > 9000)) || len(data) == 0 || len(data) > MaximumConfigBytes {
		return 0, ErrConfiguration
	}
	var v4 netip.Prefix
	var v6 []netip.Prefix
	var dns netip.AddrPort
	if !standby {
		var err error
		v4, err = netip.ParsePrefix(ipv4)
		if err != nil || !v4.Addr().Is4() {
			return 0, ErrConfiguration
		}
		if ipv6 != "" {
			p, e := netip.ParsePrefix(ipv6)
			if e != nil || !p.Addr().Is6() {
				return 0, ErrConfiguration
			}
			v6 = append(v6, p)
		}
		dns, err = netip.ParseAddrPort(dnsAddress)
		if err != nil || dns.Port() != 53 || !v4.Contains(dns.Addr()) {
			return 0, ErrConfiguration
		}
	}
	if !filepath.IsAbs(directory) {
		return 0, ErrConfiguration
	}
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return 0, ErrConfiguration
	}
	if err := checkProfile(data); err != nil {
		return 0, err
	}
	C.SetHomeDir(directory)
	debug.SetGCPercent(20)
	debug.SetMemoryLimit(35 * 1024 * 1024)
	cfg, err := executor.ParseWithBytes(data)
	if err != nil {
		return 0, ErrConfiguration
	}
	executor.ApplyConfig(cfg, true)
	cleanup := true
	defer func() {
		if cleanup {
			shutdown()
		}
	}()
	// ApplyConfig logs provider failures without returning them. Never mark an empty provider ready.
	for _, provider := range cfg.Providers {
		if provider.VehicleType() != P.Compatible && provider.Count() == 0 {
			return 0, ErrConfiguration
		}
	}
	for _, provider := range cfg.RuleProviders {
		if provider.VehicleType() != P.Compatible && provider.Count() == 0 {
			return 0, ErrConfiguration
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	var p *packetDevice
	var stack tun.Stack
	if !standby {
		handler, err := sing.NewListenerHandler(sing.ListenerConfig{Tunnel: tunnel.Tunnel, Type: C.TUN, UDPTimeout: time.Minute})
		if err != nil {
			cancel()
			return 0, ErrConfiguration
		}
		p = &packetDevice{input: make(chan []byte, 32), output: make(chan []byte, 32), done: make(chan struct{}), mtu: mtu}
		h := &singtun.ListenerHandler{ListenerHandler: handler, DnsAddrPorts: []netip.AddrPort{dns}, Inet4Address: []netip.Prefix{v4}, Inet6Address: v6, DisableICMPForwarding: true}
		stack, err = tun.NewStack("mips", tun.StackOptions{Context: ctx, Tun: p, TunOptions: tun.Options{MTU: uint32(mtu), Inet4Address: []netip.Prefix{v4}, Inet6Address: v6}, UDPTimeout: time.Minute, ICMPTimeout: time.Second, Handler: h, Logger: log.SingLogger})
		if err == nil {
			err = stack.Start()
		}
		if err != nil {
			cancel()
			_ = p.Close()
			if stack != nil {
				_ = stack.Close()
			}
			return 0, ErrConfiguration
		}
	}
	nextID++
	currentMu.Lock()
	current = &instance{id: nextID, device: p, stack: stack, cancel: cancel, logs: newLogBuffer(data), context: ctx, probes: map[string]*liveProbe{}, directory: directory, rules: rulePaths(data)}
	currentMu.Unlock()
	id := nextID
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				lifecycle.Lock()
				if current != nil && current.id == id {
					current.history.sample()
				}
				lifecycle.Unlock()
			}
		}
	}()
	cleanup = false
	return nextID, nil
}

func Stop(id uint64) {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	currentMu.Lock()
	old := current
	if old == nil || old.id != id {
		currentMu.Unlock()
		return
	}
	current = nil
	currentMu.Unlock()
	old.logs.stop()
	old.cancel()
	old.probeWorkers.Wait()
	if old.device != nil {
		_ = old.device.Close()
	}
	if old.stack != nil {
		_ = old.stack.Close()
	}
	shutdown()
}
func shutdown() {
	tunnel.OnSuspend()
	// Close adapters while the lifecycle lock is held, before the next config
	// changes global core state. Do not leave their cleanup to finalizers.
	for _, proxy := range tunnel.Proxies() {
		_ = proxy.Adapter().Close()
	}
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool { _ = c.Close(); return true })
	for _, p := range tunnel.Providers() {
		if c, ok := p.(io.Closer); ok {
			_ = c.Close()
		}
		for _, proxy := range p.Proxies() {
			_ = proxy.Adapter().Close()
		}
	}
	for _, p := range tunnel.RuleProviders() {
		if c, ok := p.(io.Closer); ok {
			_ = c.Close()
		}
	}
	executor.Shutdown()
	statistic.DefaultManager.ResetStatistic()
}

func Submit(id uint64, packet []byte) error {
	p := device(id)
	if p == nil {
		return ErrStopped
	}
	if !validPacket(packet, p.mtu) {
		return ErrPacket
	}
	select {
	case <-p.done:
		return ErrStopped
	default:
	}
	select {
	case <-p.done:
		return ErrStopped
	case p.input <- append([]byte(nil), packet...):
		return nil
	default:
		return ErrQueueFull
	}
}
func Read(id uint64, buffer []byte, timeout time.Duration) (int, error) {
	p := device(id)
	if p == nil {
		return 0, ErrStopped
	}
	if len(buffer) < MaximumPacketBytes {
		return 0, io.ErrShortBuffer
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-p.done:
		return 0, ErrStopped
	default:
	}
	select {
	case <-p.done:
		return 0, ErrStopped
	case data := <-p.output:
		return copy(buffer, data), nil
	case <-timer.C:
		return 0, nil
	}
}
func validPacket(p []byte, mtu int) bool {
	if len(p) == 0 || len(p) > mtu {
		return false
	}
	switch p[0] >> 4 {
	case 4:
		return len(p) >= 20 && int(p[0]&15)*4 >= 20 && int(p[0]&15)*4 <= len(p) && int(binary.BigEndian.Uint16(p[2:4])) == len(p)
	case 6:
		return len(p) >= 40 && int(binary.BigEndian.Uint16(p[4:6]))+40 == len(p)
	default:
		return false
	}
}

func Select(id uint64, group, node string) error {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if current == nil || current.id != id {
		return ErrStopped
	}
	return selectLocked(group, node)
}

func selectLocked(group, node string) error {
	p, ok := tunnel.Proxies()[group]
	if !ok {
		return ErrConfiguration
	}
	selector, ok := p.Adapter().(*outboundgroup.Selector)
	if !ok {
		return ErrConfiguration
	}
	previous := selector.Now()
	if selector.Set(node) != nil {
		return ErrConfiguration
	}
	if previous != "" && previous != node {
		current.history.sample()
		statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
			for _, outbound := range c.Info().Chain {
				if outbound == previous {
					_ = c.Close()
					break
				}
			}
			return true
		})
	}
	return nil
}

func checkProfile(data []byte) error {
	var raw map[string]json.RawMessage
	if json.Unmarshal(data, &raw) != nil || raw == nil {
		return ErrConfiguration
	}
	// Required values are emitted by ProfileAssembler's packet-flow variant.
	required := map[string]string{"mixed-port": "0", "port": "0", "socks-port": "0", "redir-port": "0", "tproxy-port": "0", "listeners": "[]", "tunnels": "[]", "external-controller": `""`, "external-controller-unix": `""`, "external-controller-pipe": `""`, "external-controller-tls": `""`, "external-ui": `""`, "external-ui-url": `""`, "external-doh-server": `""`, "ss-config": `""`, "vmess-config": `""`, "log-level": `"silent"`}
	for key, value := range required {
		if string(raw[key]) != value {
			return ErrConfiguration
		}
	}
	var tunOptions struct {
		Enable    bool
		AutoRoute bool `json:"auto-route"`
	}
	var dns struct{ Listen string }
	var tuic, iptables struct{ Enable bool }
	if json.Unmarshal(raw["tun"], &tunOptions) != nil || tunOptions.Enable || tunOptions.AutoRoute || json.Unmarshal(raw["dns"], &dns) != nil || dns.Listen != "" || json.Unmarshal(raw["tuic-server"], &tuic) != nil || tuic.Enable || json.Unmarshal(raw["iptables"], &iptables) != nil || iptables.Enable {
		return ErrConfiguration
	}
	return nil
}
