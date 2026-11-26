//go:build darwin

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

// utun 由系统内建，只需 helper 是 root
func ensureTunReady() (bool, string) {
	if _, err := os.Stat(kernelPath()); err != nil {
		return false, fmt.Sprintf("内核程序缺失: %s", kernelPath())
	}
	if os.Geteuid() != 0 {
		return false, "后台服务未以管理员身份运行，请重新运行安装包"
	}
	return true, ""
}

// utun 只认 root，macOS 也没有 capability 可降权
func resolveKernelUser() (int, int) { return 0, 0 }

func applyKernelCredential(_ *exec.Cmd) error { return nil }

const (
	scutilBin      = "/usr/sbin/scutil"
	lanResolverKey = "State:/Network/Service/ECYCloud-LAN/DNS"
)

// 系统 DNS 由配置里的 tun.dns-mode 让内核自己登记兜底解析器（内核是 root，进程退出即撤）。兜底解析器的空域匹配所有名字，
// helper 再为局域网后缀登记一个专用解析器交回系统原有 DNS：后缀比空域更具体，系统按后缀选它。
// 专用解析器是 scutil 会话里的临时键，会话结束（含 helper 崩溃时 scutil 读到 EOF）由 configd 自动删除
func watchTunDNS(config string, done <-chan struct{}) {
	var top struct {
		Tun struct {
			DNSMode string `json:"dns-mode"`
		} `json:"tun"`
	}
	if json.Unmarshal([]byte(config), &top) != nil || top.Tun.DNSMode != "hijack" {
		return
	}
	go func() {
		defer guard("登记局域网解析器")
		var lan lanResolver
		defer lan.close()
		var seen, checked string
		var last time.Time
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			// TUN 起停、换网都会改动网卡与地址，稳定一秒后再查；不换地址的 DNS 变化靠 30 秒复查。不每秒起 scutil，空闲时不费电
			now := interfaceFingerprint()
			if now == seen && (now != checked || time.Since(last) >= 30*time.Second) {
				checked, last = now, time.Now()
				lan.apply(lanResolverTarget())
			}
			seen = now
			select {
			case <-done:
				return
			case <-ticker.C:
			}
		}
	}()
}

// scutil 会话随 helper 退出结束，临时键由 configd 删除，不需要另外收尾
func releaseTunDNS() {}

// 局域网后缀已由专用解析器交给系统原有 DNS（lanResolver），内核配置不用改
func withSystemLanDNS(config string) (string, error) {
	return config, nil
}

func interfaceFingerprint() string {
	ifaces, _ := net.Interfaces()
	addrs, _ := net.InterfaceAddrs()
	return fmt.Sprint(ifaces, addrs)
}

var scutilToken = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)

// 内核的兜底解析器在时才需要专用解析器。系统原有 DNS 取主服务的，手动设置优先于 DHCP 下发：
// 兜底解析器生效后 State:/Network/Global/DNS 本身就成了内核的地址，不能用
func lanResolverTarget() (string, []string) {
	out, err := scutilQuery("list State:/Network/Service/sing-tun-[0-9a-f]+/DNS\nshow State:/Network/Global/IPv4\nshow State:/Network/Global/IPv6\n")
	if err != nil {
		logf("读取系统网络配置失败: %v", err)
		return "", nil
	}
	service, iface := parsePrimaryService(out)
	if service == "" {
		return "", nil
	}
	out, err = scutilQuery(fmt.Sprintf("show Setup:/Network/Service/%s/DNS\nshow State:/Network/Service/%s/DNS\n", service, service))
	if err != nil {
		logf("读取系统 DNS 失败: %v", err)
		return "", nil
	}
	return iface, parseServerAddresses(out, iface)
}

func scutilQuery(commands string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, scutilBin)
	cmd.Stdin = strings.NewReader(commands)
	out, err := cmd.Output()
	return string(out), err
}

// 从 list 与 IPv4、IPv6 全局配置里取主服务与主网卡；值要拼进 scutil 命令，逐个校验
func parsePrimaryService(out string) (string, string) {
	if !strings.Contains(out, "State:/Network/Service/sing-tun-") {
		return "", ""
	}
	var service, iface string
	for _, line := range strings.Split(out, "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), " : ")
		if !ok || !scutilToken.MatchString(value) {
			continue
		}
		if key == "PrimaryService" && service == "" {
			service = value
		} else if key == "PrimaryInterface" && iface == "" {
			iface = value
		}
	}
	if iface == "" {
		return "", ""
	}
	return service, iface
}

// 取输出里第一个 ServerAddresses 数组，每行是「0 : 192.168.1.1」；Setup 键排在前面，手动设置的 DNS 优先。
// 服务键里的链路本地地址不带网卡，系统按服务所在网卡补上；自建的键没有网卡，要补成 fe80::1%en0
func parseServerAddresses(out string, iface string) []string {
	var servers []string
	inside := false
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case line == "ServerAddresses : <array> {":
			inside = true
		case inside && line == "}":
			return servers
		case inside:
			if _, value, ok := strings.Cut(line, " : "); ok {
				if addr, err := netip.ParseAddr(value); err == nil {
					if addr.IsLinkLocalUnicast() && addr.Zone() == "" {
						addr = addr.WithZone(iface)
					}
					servers = append(servers, addr.String())
				}
			}
		}
	}
	return servers
}

type lanResolver struct {
	session *exec.Cmd
	stdin   io.WriteCloser
	target  string
}

func (l *lanResolver) apply(iface string, servers []string) {
	target := iface + " " + strings.Join(servers, " ")
	if target == l.target {
		return
	}
	l.close()
	if len(servers) == 0 {
		return
	}
	session := exec.Command(scutilBin)
	session.Stdout = scutilLog{}
	session.Stderr = scutilLog{}
	stdin, err := session.StdinPipe()
	if err == nil {
		err = session.Start()
	}
	if err != nil {
		logf("登记局域网解析器失败: %v", err)
		return
	}
	// 不加 NoSearch 时这些后缀会被并进全局搜索域，单个词的名字会被逐个补上后缀去查
	fmt.Fprintf(stdin, "d.init\nd.add ServerAddresses * %s\nd.add SupplementalMatchDomains * %s\nd.add SupplementalMatchDomainsNoSearch # 1\nadd %s temporary\n",
		strings.Join(servers, " "), strings.Join(lanDomains, " "), lanResolverKey)
	l.session, l.stdin, l.target = session, stdin, target
	// 与 sing-tun 登记兜底解析器后一样刷新缓存，免得留着此前由内核答复的 NXDOMAIN
	if err := exec.Command("/usr/bin/dscacheutil", "-flushcache").Run(); err != nil {
		logf("刷新 DNS 缓存失败: %v", err)
	}
}

// 关闭 stdin 后 scutil 读到 EOF 退出，会话里的临时键随之删除
func (l *lanResolver) close() {
	if l.session == nil {
		return
	}
	l.stdin.Close()
	if err := l.session.Wait(); err != nil {
		logf("撤销局域网解析器: %v", err)
	}
	l.session, l.stdin, l.target = nil, nil, ""
}

// scutil 交互模式只在命令出错时有输出
type scutilLog struct{}

func (scutilLog) Write(p []byte) (int, error) {
	logf("登记局域网解析器: %s", strings.TrimSpace(string(p)))
	return len(p), nil
}
