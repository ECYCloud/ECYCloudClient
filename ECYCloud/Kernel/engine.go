package kernel

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"regexp"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/pool"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener/sing"
	singtun "github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
	tun "github.com/metacubex/sing-tun"
	M "github.com/metacubex/sing/common/metadata"
)

const MaximumConfigBytes = 8 * 1024 * 1024
const MaximumPacketBytes = 65535

// 调整前先用 Tests/MihomoBridge/memory_test.go 重新量测
const MaximumTunnelConnections = 2048

var ErrConfiguration = errors.New("内核配置无效或包含扩展不支持的监听器")
var ErrNoNodes = errors.New("面板未下发任何可用节点")
var ErrStopped = errors.New("连接已停止")
var ErrPacket = errors.New("数据包格式无效")
var ErrBusy = errors.New("内核正在运行")
var ErrGeoDataInTunnel = errors.New("包隧道运行中不能更新 GeoData")
var errConnectionLimit = errors.New("并发连接数已达上限")
var errMemoryTight = errors.New("内存余量不足，暂不接受新连接")

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
	memoryDone   chan struct{}
	directory    string
	rules        map[string]string
	nodeFiles    map[string][sha256.Size]byte
	geoMu        sync.Mutex
	geoRunning   bool
	geoFailed    bool
}

// mihomo 的 HandleTCPConn 在连接结束前不返回；返回错误时协议栈重置这条新连接
type connectionLimit struct {
	tun.Handler
	active atomic.Int32
	memory *memoryGuard
}

func (l *connectionLimit) NewConnection(ctx context.Context, conn net.Conn, metadata M.Metadata) error {
	defer l.active.Add(-1)
	if l.active.Add(1) > MaximumTunnelConnections {
		return errConnectionLimit
	}
	if !l.memory.admit() {
		return errMemoryTight
	}
	return l.Handler.NewConnection(ctx, conn, metadata)
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
		defer pool.Put(data)
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
	data := pool.Get(len(b))
	copy(data, b)
	select {
	case <-p.done:
		_ = pool.Put(data)
		return 0, io.ErrClosedPipe
	case p.output <- data:
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
	// 待机实例可就地更新 GeoData，改写成规则集后更新就不再生效
	profile, geoSites := data, map[string]string(nil)
	if !standby {
		// 同一扩展进程里重启时，上一实例释放的内存还没还给系统，转换前先归还
		debug.FreeOSMemory()
		profile, geoSites = convertGeoSite(data, directory)
	}
	cfg, err := executor.ParseWithBytes(profile)
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
	// ApplyConfig logs provider failures without returning them. An empty node provider cannot carry traffic; an empty rule set only loses its rules.
	for _, provider := range cfg.Providers {
		if provider.VehicleType() != P.Compatible && provider.Count() == 0 {
			return 0, ErrNoNodes
		}
	}
	for _, provider := range cfg.RuleProviders {
		if provider.VehicleType() != P.Compatible && provider.Count() == 0 {
			log.Warnln("规则集 %s 为空，已跳过其中的规则", provider.Name())
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	var p *packetDevice
	var stack tun.Stack
	var memory *memoryGuard
	if !standby {
		memory = &memoryGuard{}
		handler, err := sing.NewListenerHandler(sing.ListenerConfig{Tunnel: tunnel.Tunnel, Type: C.TUN, UDPTimeout: time.Minute})
		if err != nil {
			cancel()
			return 0, ErrConfiguration
		}
		p = &packetDevice{input: make(chan []byte, 32), output: make(chan []byte, 32), done: make(chan struct{}), mtu: mtu}
		h := &singtun.ListenerHandler{ListenerHandler: handler, DnsAddrPorts: []netip.AddrPort{dns}, Inet4Address: []netip.Prefix{v4}, Inet6Address: v6, DisableICMPForwarding: true}
		stack, err = tun.NewStack("mips", tun.StackOptions{Context: ctx, Tun: p, TunOptions: tun.Options{MTU: uint32(mtu), Inet4Address: []netip.Prefix{v4}, Inet6Address: v6}, UDPTimeout: time.Minute, ICMPTimeout: time.Second, Handler: &connectionLimit{Handler: h, memory: memory}, Logger: log.SingLogger})
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
	current = &instance{id: nextID, device: p, stack: stack, cancel: cancel, logs: newLogBuffer(data, geoSites), history: connectionHistory{geoSites: geoSites}, context: ctx, probes: map[string]*liveProbe{}, directory: directory, rules: rulePaths(data), nodeFiles: map[string][sha256.Size]byte{}}
	if files, _, err := panelNodeFiles(data); err == nil {
		for name, body := range files {
			current.nodeFiles[name] = sha256.Sum256(body)
		}
	}
	// 守护协程会写日志，停止时须等它退出，否则与下一次启动改日志级别竞争（mihomo log 包未加锁）
	if memory != nil {
		current.memoryDone = make(chan struct{})
		go func(done chan struct{}) { defer close(done); memory.run(ctx) }(current.memoryDone)
	}
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
	// 启动时用过的临时内存释放后仍计入扩展占用，后台归还慢
	if !standby {
		debug.FreeOSMemory()
	}
	cleanup = false
	return nextID, nil
}

var panelProvider = regexp.MustCompile(`^ecy-panel-(nodes|[a-f0-9]{64})$`)

// 各面板节点文件应有的内容与其中的节点名
func panelNodeFiles(data []byte) (map[string][]byte, map[string][]string, error) {
	var config struct {
		Providers map[string]struct {
			Type    string
			Path    string
			Payload []json.RawMessage
		} `json:"proxy-providers"`
	}
	if json.Unmarshal(data, &config) != nil {
		return nil, nil, ErrConfiguration
	}
	files := map[string][]byte{}
	names := map[string][]string{}
	for name, item := range config.Providers {
		if !strings.HasPrefix(name, "ecy-panel-") {
			continue
		}
		if !panelProvider.MatchString(name) || item.Type != "file" || item.Path != name+".json" || len(item.Payload) == 0 {
			return nil, nil, ErrConfiguration
		}
		body, err := json.Marshal(map[string]any{"proxies": item.Payload})
		if err != nil {
			return nil, nil, ErrConfiguration
		}
		files[name] = body
		for _, raw := range item.Payload {
			var node struct{ Name string }
			if json.Unmarshal(raw, &node) != nil || node.Name == "" {
				return nil, nil, ErrConfiguration
			}
			names[name] = append(names[name], node.Name)
		}
	}
	return files, names, nil
}

// UpdateNodes 只重写面板节点文件并让内核重读，不重建内核，已有连接不断开。
// 调用方须先确认其余配置与运行中的一致（TunnelLease.differsOnlyInNodes）。
func UpdateNodes(id uint64, data []byte) error {
	if len(data) == 0 || len(data) > MaximumConfigBytes {
		return ErrConfiguration
	}
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if current == nil || current.id != id {
		return ErrStopped
	}
	if err := checkProfile(data); err != nil {
		return err
	}
	files, names, err := panelNodeFiles(data)
	if err != nil || files["ecy-panel-nodes"] == nil {
		return ErrConfiguration
	}
	running := tunnel.Providers()
	sums := map[string][sha256.Size]byte{}
	for name, body := range files {
		if running[name] == nil {
			return ErrConfiguration
		}
		// 内容没变的节点文件不重写：内核重读时会换掉其中全部出站，测试未装入的节点只该动探测节点文件
		if sum := sha256.Sum256(body); sum != current.nodeFiles[name] {
			sums[name] = sum
		}
	}
	for name := range sums {
		target := filepath.Join(current.directory, name+".json")
		if err := os.WriteFile(target+".tmp", files[name], 0600); err != nil {
			return ErrConfiguration
		}
		if err := os.Rename(target+".tmp", target); err != nil {
			return ErrConfiguration
		}
	}
	// 内核自己监视节点文件，改名后约 100 毫秒自动重读；此时再调 Update 会与它并发改同一个 Fetcher，超时仍未重读才手动触发
	loaded := func(name string) bool {
		proxies := running[name].Proxies()
		if len(proxies) != len(names[name]) {
			return false
		}
		for index, proxy := range proxies {
			if proxy.Name() != names[name][index] {
				return false
			}
		}
		return true
	}
	deadline := time.Now().Add(2 * time.Second)
	for name, sum := range sums {
		for !loaded(name) {
			if time.Now().After(deadline) {
				if err := running[name].Update(); err != nil || !loaded(name) {
					return ErrConfiguration
				}
				break
			}
			time.Sleep(20 * time.Millisecond)
		}
		current.nodeFiles[name] = sum
	}
	current.logs.mu.Lock()
	current.logs.secrets = logSecrets(data)
	current.logs.mu.Unlock()
	return nil
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
	if old.memoryDone != nil {
		<-old.memoryDone
	}
	// GeoData 更新不接受取消，单个文件最长下载 90 秒：先停止受理新连接，等待期间持续关闭已有连接，让它随下载失败退出
	tunnel.OnSuspend()
	workers := make(chan struct{})
	go func() {
		old.probeWorkers.Wait()
		close(workers)
	}()
	for waiting := true; waiting; {
		closeConnections()
		select {
		case <-workers:
			waiting = false
		case <-time.After(100 * time.Millisecond):
		}
	}
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
	closeConnections()
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

func closeConnections() {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool { _ = c.Close(); return true })
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
	data := pool.Get(len(packet))
	copy(data, packet)
	select {
	case <-p.done:
		_ = pool.Put(data)
		return ErrStopped
	case p.input <- data:
		return nil
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
	deliver := func(data []byte) (int, error) {
		n := copy(buffer, data)
		_ = pool.Put(data)
		return n, nil
	}
	select {
	case <-p.done:
		return 0, ErrStopped
	default:
	}
	select {
	case data := <-p.output:
		return deliver(data)
	default:
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-p.done:
		return 0, ErrStopped
	case data := <-p.output:
		return deliver(data)
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
	if !httpsDownloads(raw) {
		return ErrConfiguration
	}
	return nil
}

// 明文下载会被链路上替换规则集、节点订阅与地理数据库：只检查不改写，与 ProfileAssembler 同口径。
// 内核取 provider 字段时名字不分大小写（mihomo common/structure），URL、Url 一样会被拿去下载
func httpsDownloads(raw map[string]json.RawMessage) bool {
	var geox map[string]any
	if json.Unmarshal(raw["geox-url"], &geox) == nil {
		for _, url := range geox {
			if !httpsURL(url) {
				return false
			}
		}
	}
	for _, section := range []string{"proxy-providers", "rule-providers"} {
		var providers map[string]json.RawMessage
		if json.Unmarshal(raw[section], &providers) != nil {
			continue
		}
		for _, provider := range providers {
			var fields map[string]any
			_ = json.Unmarshal(provider, &fields)
			for key, url := range fields {
				if strings.EqualFold(key, "url") && !httpsURL(url) {
					return false
				}
			}
		}
	}
	return true
}

// 没有地址的本地 provider 不受影响
func httpsURL(value any) bool {
	text, ok := value.(string)
	text = strings.ToLower(strings.TrimSpace(text))
	return value == nil || (ok && (text == "" || strings.HasPrefix(text, "https://")))
}
