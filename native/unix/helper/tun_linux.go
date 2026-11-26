//go:build linux

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

const tunDevice = "/dev/net/tun"

// 容器与部分精简发行版默认不带 tun 模块，内核起来后才报错就来不及给提示了
func ensureTunReady() (bool, string) {
	if _, err := os.Stat(kernelPath()); err != nil {
		return false, fmt.Sprintf("内核程序缺失: %s", kernelPath())
	}
	if _, err := os.Stat(tunDevice); err != nil {
		return false, fmt.Sprintf("系统缺少 %s，请执行 sudo modprobe tun 后重试", tunDevice)
	}
	if os.Geteuid() != 0 {
		return false, "后台服务未以 root 身份运行，请检查 ecycloud-helper.service"
	}
	return true, ""
}

var tunNamePattern = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,15}$`)

// 内核以 ecycloud 账户运行，sing-tun 自己为 TUN 网卡执行的 resolvectl 会被 systemd-resolved 以「需要交互授权」拒绝，
// 错误又被丢弃（tun_linux.go 的 setSearchDomainForSystemdResolved）；局域网 DNS 落在 route-exclude-address 里，
// dns-hijack 也拦不到，系统解析就绕过了内核。由 root 的 helper 在网卡出现（含重建、热打开）后照原样补设，网卡消失时 resolved 自行丢弃
func watchTunDNS(config string, done <-chan struct{}) {
	name := tunDNSDevice(config)
	if name == "" {
		return
	}
	ctl := resolvedCtl()
	if ctl == "" {
		watchDNSRedirect(name, tunExcludedPrefixes(config), done)
		return
	}
	go func() {
		defer guard("设置 TUN 的系统 DNS")
		defer lanRoutes.release(ctl)
		applied := 0
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for tick := 1; ; tick++ {
			iface, err := net.InterfaceByName(name)
			switch {
			case err != nil:
				lanRoutes.release(ctl)
			case iface.Index != applied:
				if addrs, err := iface.Addrs(); err == nil {
					if servers := tunDNSServers(addrs); len(servers) > 0 {
						applied = iface.Index
						if err := setTunDNS(ctl, name, servers); err != nil {
							logf("设置 TUN 的系统 DNS 失败: %v", err)
						}
						lanRoutes.sync(ctl, name, done)
					}
				}
			case tick%5 == 0:
				lanRoutes.sync(ctl, name, done)
			}
			select {
			case <-done:
				return
			case <-ticker.C:
			}
		}
	}()
}

// 不看 tun.enable：待机内核以关闭的 TUN 启动，连接时 GUI 经控制口热打开（connection_controller 的 setTunEnabled），
// 不再经过 helper；只开系统代理时网卡不会出现，也就不会执行 resolvectl
func tunDNSDevice(config string) string {
	var top struct {
		Tun struct {
			AutoRoute bool   `json:"auto-route"`
			Device    string `json:"device"`
		} `json:"tun"`
	}
	if json.Unmarshal([]byte(config), &top) != nil || !top.Tun.AutoRoute || !tunNamePattern.MatchString(top.Tun.Device) {
		return ""
	}
	return top.Tun.Device
}

// 与 sing-tun 的 Inet4DNSAddress / Inet6DNSAddress 同算法：各取网卡第一个地址的下一个地址
func tunDNSServers(addrs []net.Addr) []netip.Addr {
	var v4, v6 netip.Addr
	for _, addr := range addrs {
		network, ok := addr.(*net.IPNet)
		if !ok {
			continue
		}
		ip, ok := netip.AddrFromSlice(network.IP)
		if !ok {
			continue
		}
		ip = ip.Unmap()
		ones, _ := network.Mask.Size()
		prefix := netip.PrefixFrom(ip, ones)
		next := ip.Next()
		if !next.IsValid() || !prefix.Contains(next) || ip.IsLinkLocalUnicast() {
			continue
		}
		if ip.Is4() && !v4.IsValid() {
			v4 = next
		} else if ip.Is6() && !v6.IsValid() {
			v6 = next
		}
	}
	var servers []netip.Addr
	for _, server := range []netip.Addr{v4, v6} {
		if server.IsValid() {
			servers = append(servers, server)
		}
	}
	return servers
}

func setTunDNS(ctl string, name string, servers []netip.Addr) error {
	dns := []string{"dns", name}
	for _, server := range servers {
		dns = append(dns, server.String())
	}
	for _, args := range [][]string{{"domain", name, "~."}, {"default-route", name, "true"}, dns} {
		if _, err := resolvectl(ctl, args...); err != nil {
			return err
		}
	}
	return nil
}

func resolvectl(ctl string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, ctl, args...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("resolvectl %s: %v %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

// TUN 的 ~. 把所有名字都交给内核；给有 DNS 的物理网卡加上局域网后缀的路由域，后缀比 ~. 更具体，
// systemd-resolved 就把这些名字交给该网卡的 DNS（通常是路由器）。NetworkManager 等重新下发网卡配置时会整体覆盖，所以定时补；撤销时只撤自己加的。
// 留下的 ~ 路由域会让网卡失去默认 DNS 路由，断开后普通名字全部解析失败，所以加过的先记进文件：helper 退出时同步撤销，
// 被强杀、崩溃后由 systemd 拉起时按记录撤销。文件放在 /var/run 下，开机即清空，与 resolved 的运行时配置同生命周期
var lanRoutes = lanRouting{added: map[string][]string{}}

type lanRouting struct {
	mu      sync.Mutex
	added   map[string][]string
	lastErr string
}

func lanRoutesState() string {
	return filepath.Join(filepath.Dir(socketPath), "lan-domains.json")
}

func (l *lanRouting) sync(ctl string, tun string, done <-chan struct{}) {
	l.mu.Lock()
	defer l.mu.Unlock()
	// 收尾时的撤销可能先拿到锁，内核已退出就不能再加回去
	select {
	case <-done:
		return
	default:
	}
	links, err := resolvedLinks(ctl)
	if err == nil {
		for name, link := range links {
			if name == tun || len(link.servers) == 0 || !tunNamePattern.MatchString(name) {
				continue
			}
			missing := missingLanDomains(link.domains)
			if len(missing) == 0 {
				continue
			}
			// 先记后加：两步之间被强杀也不会漏撤
			l.record(name, missing)
			if err = l.save(); err != nil {
				break
			}
			if err = setLinkDomains(ctl, name, append(link.domains, missing...)); err != nil {
				break
			}
		}
	}
	// 每 5 秒都会重试，同样的错误只记一次
	switch {
	case err == nil:
		l.lastErr = ""
	case err.Error() != l.lastErr:
		l.lastErr = err.Error()
		logf("把局域网后缀交给网卡 DNS 失败: %v", err)
	}
}

// 读不到网卡配置时保留记录，留给下一次撤销或下次启动
func (l *lanRouting) release(ctl string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.added) == 0 {
		return
	}
	links, err := resolvedLinks(ctl)
	if err != nil {
		return
	}
	for name, ours := range l.added {
		if link, ok := links[name]; ok {
			if kept := withoutDomains(link.domains, ours); len(kept) != len(link.domains) {
				if err := setLinkDomains(ctl, name, kept); err != nil {
					logf("撤销网卡 %s 的局域网后缀失败: %v", name, err)
				}
			}
		}
	}
	l.added = map[string][]string{}
	if err := os.Remove(lanRoutesState()); err != nil && !errors.Is(err, os.ErrNotExist) {
		logf("删除局域网后缀记录失败: %v", err)
	}
}

// 网卡被反复覆盖、补回时同一后缀只记一次
func (l *lanRouting) record(name string, domains []string) {
	for _, domain := range domains {
		if !slices.Contains(l.added[name], domain) {
			l.added[name] = append(l.added[name], domain)
		}
	}
}

func (l *lanRouting) save() error {
	data, err := json.Marshal(l.added)
	if err != nil {
		return err
	}
	return os.WriteFile(lanRoutesState(), data, 0o600)
}

// helper 启动时与退出前调用：退出时内核已停，监视协程的撤销来不及跑；启动时的记录来自上次没能收尾的进程
func releaseTunDNS() {
	if ipCmd, err := exec.LookPath("ip"); err == nil {
		dnsRedirect.release(ipCmd)
	}
	ctl, err := exec.LookPath("resolvectl")
	if err != nil {
		return
	}
	lanRoutes.mu.Lock()
	var recorded map[string][]string
	if data, err := os.ReadFile(lanRoutesState()); err == nil && json.Unmarshal(data, &recorded) == nil {
		for name, domains := range recorded {
			lanRoutes.record(name, domains)
		}
	}
	lanRoutes.mu.Unlock()
	lanRoutes.release(ctl)
}

type resolvedLink struct {
	servers []string
	domains []string
}

var resolvedLinkLine = regexp.MustCompile(`^Link \d+ \(([^)]+)\):(.*)$`)

func resolvedLinks(ctl string) (map[string]*resolvedLink, error) {
	dns, err := resolvectl(ctl, "dns")
	if err != nil {
		return nil, err
	}
	domain, err := resolvectl(ctl, "domain")
	if err != nil {
		return nil, err
	}
	return parseResolvedLinks(dns, domain), nil
}

// 解析 resolvectl dns / domain 的「Link 2 (eth0): …」行
func parseResolvedLinks(dns string, domain string) map[string]*resolvedLink {
	links := map[string]*resolvedLink{}
	for i, out := range []string{dns, domain} {
		for _, line := range strings.Split(out, "\n") {
			match := resolvedLinkLine.FindStringSubmatch(strings.TrimSpace(line))
			if match == nil {
				continue
			}
			link := links[match[1]]
			if link == nil {
				link = &resolvedLink{}
				links[match[1]] = link
			}
			if i == 0 {
				link.servers = strings.Fields(match[2])
			} else {
				link.domains = strings.Fields(match[2])
			}
		}
	}
	return links
}

// 搜索域同样充当路由域，已有 lan 或 ~lan 都不再加
func missingLanDomains(domains []string) []string {
	var missing []string
	for _, suffix := range lanDomains {
		present := false
		for _, domain := range domains {
			present = present || domain == suffix || domain == "~"+suffix
		}
		if !present {
			missing = append(missing, "~"+suffix)
		}
	}
	return missing
}

func withoutDomains(domains []string, remove []string) []string {
	var kept []string
	for _, domain := range domains {
		if !slices.Contains(remove, domain) {
			kept = append(kept, domain)
		}
	}
	return kept
}

// resolvectl 以唯一的空字符串参数表示清空
func setLinkDomains(ctl string, name string, domains []string) error {
	if len(domains) == 0 {
		domains = []string{""}
	}
	_, err := resolvectl(ctl, append([]string{"domain", name}, domains...)...)
	return err
}

// resolvectl 在而 resolved 没有运行（禁用、屏蔽）时命令全部失败，按没有 resolved 处理
func resolvedCtl() string {
	ctl, err := exec.LookPath("resolvectl")
	if err != nil {
		return ""
	}
	if _, err := resolvectl(ctl, "dns"); err != nil {
		return ""
	}
	return ctl
}

func tunExcludedPrefixes(config string) []netip.Prefix {
	var top struct {
		Tun struct {
			Exclude []string `json:"route-exclude-address"`
		} `json:"tun"`
	}
	_ = json.Unmarshal([]byte(config), &top)
	var prefixes []netip.Prefix
	for _, value := range top.Tun.Exclude {
		if prefix, err := netip.ParsePrefix(value); err == nil {
			prefixes = append(prefixes, prefix)
		}
	}
	return prefixes
}

// 没有 systemd-resolved 时 /etc/resolv.conf 直接写路由器等局域网 DNS，这些地址落在 route-exclude-address 里，
// 查询不进 TUN、dns-hijack 拦不到。按目的地址加 53 端口单独加策略规则，把这部分查询引进 TUN；
// 内核自己的出站绑在物理网卡上，查不到这张表里经 TUN 的路由，照常走原网卡。规则与表按固定优先级和表号认领
const (
	dnsRedirectPriority = "8999"
	dnsRedirectTable    = "2023"
)

var dnsRedirect dnsRedirection

type dnsRedirection struct {
	mu      sync.Mutex
	index   int
	servers []netip.Addr
	lastErr string
}

func watchDNSRedirect(tun string, excluded []netip.Prefix, done <-chan struct{}) {
	ipCmd, err := exec.LookPath("ip")
	if err != nil {
		logf("找不到 ip 命令，无法把系统 DNS 引进 TUN: %v", err)
		return
	}
	go func() {
		defer guard("把系统 DNS 引进 TUN")
		defer dnsRedirect.release(ipCmd)
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for tick := 1; ; tick++ {
			// resolv.conf 随换网改写、规则可能被网络管理器清掉，每 5 秒核对一次
			// 只开系统代理时网卡一直不在，没设过就不必每秒调 ip；残留由 helper 启停时的 releaseTunDNS 兜底
			if iface, err := net.InterfaceByName(tun); err != nil {
				if dnsRedirect.appliedIndex() != 0 {
					dnsRedirect.release(ipCmd)
				}
			} else if iface.Index != dnsRedirect.appliedIndex() || tick%5 == 0 {
				dnsRedirect.sync(ipCmd, iface, excluded, done)
			}
			select {
			case <-done:
				return
			case <-ticker.C:
			}
		}
	}()
}

func (d *dnsRedirection) appliedIndex() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.index
}

func (d *dnsRedirection) sync(ipCmd string, iface *net.Interface, excluded []netip.Prefix, done <-chan struct{}) {
	d.mu.Lock()
	defer d.mu.Unlock()
	select {
	case <-done:
		return
	default:
	}
	conf, err := os.ReadFile("/etc/resolv.conf")
	servers := redirectedServers(string(conf), excluded)
	if err == nil {
		var rules string
		rules, err = runIP(ipCmd, "-4", "rule", "show", "priority", dnsRedirectPriority)
		// 不为换网热载内核：内核的 system 解析器 5 分钟才重读 resolv.conf（mihomo dns/system.go 的 SystemDnsFlushTime），
		// 但热载会重新初始化节点订阅并关闭经它的全部连接（adapter/provider/provider.go 的 closeAllConnections）
		if err == nil && (iface.Index != d.index || !slices.Equal(servers, d.servers) || strings.Count(rules, "lookup") != len(servers)) {
			err = d.apply(ipCmd, iface.Name, servers)
			d.index = iface.Index
		}
	}
	switch {
	case err == nil:
		d.lastErr = ""
	case err.Error() != d.lastErr:
		d.lastErr = err.Error()
		logf("把系统 DNS 引进 TUN 失败: %v", err)
	}
}

func (d *dnsRedirection) apply(ipCmd string, tun string, servers []netip.Addr) error {
	d.clear(ipCmd)
	d.servers = nil
	for _, server := range servers {
		target := netip.PrefixFrom(server, 32).String()
		if _, err := runIP(ipCmd, "-4", "route", "replace", target, "dev", tun, "table", dnsRedirectTable); err != nil {
			return err
		}
		if _, err := runIP(ipCmd, "-4", "rule", "add", "priority", dnsRedirectPriority, "to", target, "dport", "53", "table", dnsRedirectTable); err != nil {
			return err
		}
		d.servers = append(d.servers, server)
	}
	return nil
}

func (d *dnsRedirection) release(ipCmd string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.clear(ipCmd)
	d.index = 0
	d.servers = nil
}

func (d *dnsRedirection) clear(ipCmd string) {
	for i := 0; i < 64; i++ {
		if _, err := runIP(ipCmd, "-4", "rule", "del", "priority", dnsRedirectPriority, "table", dnsRedirectTable); err != nil {
			break
		}
	}
	_, _ = runIP(ipCmd, "-4", "route", "flush", "table", dnsRedirectTable)
}

// 回环上的本机缓存（如 NetworkManager 的 dnsmasq）进不了 TUN；IPv6 的链路本地地址带网卡作用域，同样不引
func redirectedServers(resolvConf string, excluded []netip.Prefix) []netip.Addr {
	var servers []netip.Addr
	for _, line := range strings.Split(resolvConf, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 || fields[0] != "nameserver" {
			continue
		}
		addr, err := netip.ParseAddr(fields[1])
		if err != nil || !addr.Is4() || addr.IsLoopback() || slices.Contains(servers, addr) {
			continue
		}
		for _, prefix := range excluded {
			if prefix.Contains(addr) {
				servers = append(servers, addr)
				break
			}
		}
	}
	return servers
}

func runIP(ipCmd string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, ipCmd, args...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("ip %s: %v %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

// 没有 resolved 时系统 DNS 被引进 TUN（dnsRedirect），只有路由器认识的局域网名字也进了内核、经代理查不到：
// 给这些后缀指定 system（即 /etc/resolv.conf 里的路由器）并排除出 fake-ip，应用拿到局域网真实地址。
// 有 resolved 时 system 会经 127.0.0.53 绕回内核形成回环，这些名字改由网卡路由域交给路由器（lanRoutes）
func withSystemLanDNS(config string) (string, error) {
	if resolvedCtl() != "" {
		return config, nil
	}
	out, err := filterObject([]byte(config), func(key string, value json.RawMessage) (json.RawMessage, bool, error) {
		if key != "dns" {
			return value, true, nil
		}
		dns, err := lanDNSSection(value)
		return dns, true, err
	})
	if err != nil {
		return "", err
	}
	var pretty bytes.Buffer
	if err := json.Indent(&pretty, out, "", "  "); err != nil {
		return "", fmt.Errorf("重写配置失败: %w", err)
	}
	return pretty.String(), nil
}

// 面板给过的后缀不覆盖；nameserver-policy 按原顺序追加，fake-ip-filter 只在黑名单模式下追加
func lanDNSSection(raw json.RawMessage) (json.RawMessage, error) {
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || fields == nil {
		return raw, nil
	}
	policy := fields["nameserver-policy"]
	if policy == nil {
		policy = json.RawMessage(`{}`)
	}
	var policies map[string]json.RawMessage
	if json.Unmarshal(policy, &policies) != nil || policies == nil {
		return raw, nil
	}
	var mode string
	_ = json.Unmarshal(fields["fake-ip-filter-mode"], &mode)
	var filter []string
	editFilter := (mode == "" || mode == "blacklist") &&
		(fields["fake-ip-filter"] == nil || json.Unmarshal(fields["fake-ip-filter"], &filter) == nil)
	var err error
	for _, suffix := range lanDomains {
		key := "+." + suffix
		if _, ok := policies[key]; !ok {
			if policy, err = withField(policy, key, json.RawMessage(`"system"`)); err != nil {
				return nil, err
			}
		}
		if editFilter && !slices.Contains(filter, key) {
			filter = append(filter, key)
		}
	}
	out, err := withField(raw, "nameserver-policy", policy)
	if err != nil || !editFilter {
		return out, err
	}
	encoded, err := json.Marshal(filter)
	if err != nil {
		return nil, err
	}
	return withField(out, "fake-ip-filter", encoded)
}

// 按原有键顺序改写一个字段，没有就追加到末尾
func withField(raw []byte, key string, value json.RawMessage) ([]byte, error) {
	found := false
	out, err := filterObject(raw, func(name string, current json.RawMessage) (json.RawMessage, bool, error) {
		if name != key {
			return current, true, nil
		}
		found = true
		return value, true, nil
	})
	if err != nil || found {
		return out, err
	}
	field := strconv.Quote(key) + ":" + string(value) + "}"
	if len(out) > 2 {
		field = "," + field
	}
	return append(out[:len(out)-1], field...), nil
}
