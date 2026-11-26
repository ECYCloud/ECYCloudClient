package bridgevalidation

import (
	"bytes"
	"context"
	"ecycloud/apple/Kernel"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/metacubex/mipstack"
	"github.com/miekg/dns"
)

func packetProfile(port int) map[string]any {
	value := map[string]any{
		"mode": "rule", "log-level": "silent", "allow-lan": false, "ipv6": true,
		"tun":          map[string]bool{"enable": false, "auto-route": false},
		"dns":          map[string]any{"enable": true, "listen": "", "use-hosts": true, "nameserver": []string{"127.0.0.1:9"}},
		"hosts":        map[string]string{"synthetic.example.test": "192.0.2.44"},
		"profile":      map[string]bool{"store-selected": false, "store-fake-ip": false},
		"proxies":      []any{map[string]any{"name": "synthetic", "type": "socks5", "server": "127.0.0.1", "port": port, "udp": true}},
		"proxy-groups": []any{map[string]any{"name": "select", "type": "select", "proxies": []string{"synthetic", "REJECT"}}},
		"rules":        []string{"MATCH,select"},
	}
	for _, key := range []string{"mixed-port", "port", "socks-port", "redir-port", "tproxy-port"} {
		value[key] = 0
	}
	for _, key := range []string{"external-controller", "external-controller-unix", "external-controller-pipe", "external-controller-tls", "external-ui", "external-ui-url", "external-doh-server", "ss-config", "vmess-config"} {
		value[key] = ""
	}
	for _, key := range []string{"listeners", "tunnels"} {
		value[key] = []any{}
	}
	for _, key := range []string{"tuic-server", "iptables"} {
		value[key] = map[string]bool{"enable": false}
	}
	return value
}
func startPacketCore(t *testing.T, profile map[string]any) uint64 {
	t.Helper()
	data, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	if err = os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	id, err := kernel.Start(data, directory, 1500, "198.18.0.1/30", "fd00::1/126", "198.18.0.1:53")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { kernel.Stop(id) })
	return id
}
func packetClient(t *testing.T, id uint64) *mipstack.Stack {
	t.Helper()
	client, err := mipstack.New(mipstack.Config{MTU: 1500, LocalAddresses: []netip.Prefix{netip.MustParsePrefix("198.18.0.2/30"), netip.MustParsePrefix("fd00::2/126")}, Routes: []mipstack.Route{{Destination: netip.MustParsePrefix("0.0.0.0/0")}, {Destination: netip.MustParsePrefix("::/0")}}})
	if err != nil {
		t.Fatal(err)
	}
	if err = client.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })
	go func() {
		buffers := [][]byte{make([]byte, 1500)}
		sizes := make([]int, 1)
		for {
			n, e := client.Read(buffers, sizes, 0)
			if e != nil {
				return
			}
			for i := 0; i < n; i++ {
				if kernel.Submit(id, buffers[i][:sizes[i]]) != nil {
					return
				}
			}
		}
	}()
	go func() {
		buffer := make([]byte, kernel.MaximumPacketBytes)
		for {
			n, e := kernel.Read(id, buffer, time.Second)
			if e != nil {
				return
			}
			if n > 0 {
				if _, e = client.Write([][]byte{buffer[:n]}, 0); e != nil {
					return
				}
			}
		}
	}()
	return client
}
func TestPacketTCPIPv4IPv6AndDNS(t *testing.T) {
	proxy, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()
	go func() {
		for {
			c, e := proxy.Accept()
			if e != nil {
				return
			}
			go func() {
				defer c.Close()
				_ = c.SetDeadline(time.Now().Add(10 * time.Second))
				head := make([]byte, 2)
				if _, e := io.ReadFull(c, head); e != nil {
					return
				}
				if _, e := io.CopyN(io.Discard, c, int64(head[1])); e != nil {
					return
				}
				_, _ = c.Write([]byte{5, 0})
				req := make([]byte, 4)
				if _, e := io.ReadFull(c, req); e != nil {
					return
				}
				var size int64
				switch req[3] {
				case 1:
					size = 6
				case 4:
					size = 18
				default:
					return
				}
				if _, e := io.CopyN(io.Discard, c, size); e != nil {
					return
				}
				_, _ = c.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 1})
				_, _ = io.Copy(c, c)
			}()
		}
	}()
	id := startPacketCore(t, packetProfile(proxy.Addr().(*net.TCPAddr).Port))
	client := packetClient(t, id)
	for _, remote := range []string{"192.0.2.1:8888", "[2001:db8::1]:8888"} {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		connection, e := client.DialTCP(ctx, "tcp", netip.AddrPort{}, netip.MustParseAddrPort(remote))
		cancel()
		if e != nil {
			t.Fatal(e)
		}
		_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
		payload := bytes.Repeat([]byte("synthetic-tcp-data"), 1024)
		sent := make(chan error, 1)
		go func() { _, e := connection.Write(payload); sent <- e }()
		response := make([]byte, len(payload))
		_, e = io.ReadFull(connection, response)
		if e != nil {
			t.Fatal(e)
		}
		if e = <-sent; e != nil {
			t.Fatal(e)
		}
		if !bytes.Equal(payload, response) {
			t.Fatal("TCP payload differs")
		}
		_ = connection.Close()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	connection, err := client.DialUDP(ctx, "udp", netip.AddrPort{}, netip.MustParseAddrPort("198.18.0.1:53"))
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
	query := new(dns.Msg)
	query.SetQuestion("synthetic.example.test.", dns.TypeA)
	data, _ := query.Pack()
	if _, err = connection.Write(data); err != nil {
		t.Fatal(err)
	}
	buffer := make([]byte, 1500)
	n, err := connection.Read(buffer)
	if err != nil {
		t.Fatal(err)
	}
	response := new(dns.Msg)
	if err = response.Unpack(buffer[:n]); err != nil {
		t.Fatal(err)
	}
	if response.Id != query.Id || len(response.Answer) != 1 {
		t.Fatal("unexpected DNS reply")
	}
	if answer, ok := response.Answer[0].(*dns.A); !ok || answer.A.String() != "192.0.2.44" {
		t.Fatal("DNS did not use the configured host")
	}
	if kernel.Select(id, "select", "missing") == nil {
		t.Fatal("selected nonexistent node")
	}
	if err = kernel.Select(id, "select", "REJECT"); err != nil {
		t.Fatal(err)
	}
	kernel.Stop(id)
	if kernel.Select(id, "select", "synthetic") != kernel.ErrStopped {
		t.Fatal("stopped core accepted selection")
	}
}

func TestRejectsNetworkListenersBeforeStarting(t *testing.T) {
	for _, key := range []string{"mixed-port", "port", "socks-port", "redir-port", "tproxy-port", "external-controller", "listeners", "tun", "dns", "tuic-server"} {
		t.Run(key, func(t *testing.T) {
			profile := packetProfile(9)
			switch key {
			case "external-controller":
				profile[key] = "127.0.0.1:9090"
			case "listeners":
				profile[key] = []any{map[string]any{"type": "mixed", "port": 34567}}
			case "tun", "tuic-server":
				profile[key] = map[string]bool{"enable": true}
			case "dns":
				profile[key] = map[string]string{"listen": "127.0.0.1:1053"}
			default:
				profile[key] = 34567
			}
			data, _ := json.Marshal(profile)
			directory := t.TempDir()
			_ = os.Chmod(directory, 0700)
			id, err := kernel.Start(data, directory, 1500, "198.18.0.1/30", "", "198.18.0.1:53")
			if id != 0 {
				kernel.Stop(id)
				t.Fatal("unsafe core started")
			}
			if err != kernel.ErrConfiguration {
				t.Fatal(err)
			}
		})
	}
}

// geox-url 与 provider 地址只收 https；内联 provider 不联网，修复前这些配置都能直接启动
func TestRejectsPlaintextDownloadsBeforeStarting(t *testing.T) {
	rules := func(key, url string) map[string]any {
		return map[string]any{"ads": map[string]any{"type": "inline", "behavior": "domain", key: url, "payload": []string{"synthetic.example.test"}}}
	}
	for name, mutate := range map[string]func(map[string]any){
		"geox-url": func(p map[string]any) {
			p["geox-url"] = map[string]string{"mmdb": "https://example.test/geoip.metadb", "geosite": "http://example.test/GeoSite.dat"}
		},
		"rule-providers": func(p map[string]any) { p["rule-providers"] = rules("url", "http://example.test/ads.yaml") },
		"rule-providers URL": func(p map[string]any) {
			p["rule-providers"] = rules("URL", " HTTP://example.test/ads.yaml")
		},
		"proxy-providers": func(p map[string]any) {
			p["proxy-providers"] = map[string]any{"ecy-panel-nodes": map[string]any{"type": "inline", "url": "http://example.test/nodes.yaml", "payload": p["proxies"]}}
			p["proxies"] = []any{}
			p["proxy-groups"] = []any{map[string]any{"name": "select", "type": "select", "use": []string{"ecy-panel-nodes"}}}
		},
	} {
		t.Run(name, func(t *testing.T) {
			profile := packetProfile(9)
			mutate(profile)
			data, _ := json.Marshal(profile)
			directory := t.TempDir()
			_ = os.Chmod(directory, 0700)
			id, err := kernel.Start(data, directory, 1500, "198.18.0.1/30", "", "198.18.0.1:53")
			if id != 0 {
				kernel.Stop(id)
				t.Fatal("plaintext download source started")
			}
			if err != kernel.ErrConfiguration {
				t.Fatal(err)
			}
		})
	}
	profile := packetProfile(9)
	profile["geox-url"] = map[string]string{"mmdb": "HTTPS://example.test/geoip.metadb", "asn": ""}
	profile["rule-providers"] = rules("url", "https://example.test/ads.yaml")
	kernel.Stop(startPacketCore(t, profile))
}

// 改写受监视文件或反复启停的测试放进单独子进程：fswatch 的 100 毫秒去抖回调不随 Stop 取消，会在内核停止后
// 读 mihomo 未加锁的全局日志级别，与后续 Start 里的 log.SetLevel 构成上游自身的数据竞争，会误伤同进程的其它测试
func isolated(t *testing.T) bool {
	if os.Getenv("ECY_ISOLATED_TEST") == t.Name() {
		return false
	}
	command := exec.Command(os.Args[0], "-test.run=^"+t.Name()+"$", "-test.count=1")
	command.Env = append(os.Environ(), "ECY_ISOLATED_TEST="+t.Name())
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("%v\n%s", err, output)
	}
	return true
}

// 隧道进程常驻：带文件型规则集的内核反复启停，fswatch 与 fsnotify 的监视协程须随 Stop 退出，不能累积
func TestRestartsDoNotAccumulateProviderWatchers(t *testing.T) {
	if isolated(t) {
		return
	}
	cycle := func() {
		directory := t.TempDir()
		if err := os.Chmod(directory, 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(directory, "rules.yaml"), []byte("payload:\n  - example.test\n"), 0600); err != nil {
			t.Fatal(err)
		}
		profile := packetProfile(9)
		profile["rule-providers"] = map[string]any{"declared": map[string]any{"type": "file", "behavior": "domain", "path": "rules.yaml"}}
		data, _ := json.Marshal(profile)
		id, err := kernel.Start(data, directory, 1500, "198.18.0.1/30", "", "198.18.0.1:53")
		if err != nil {
			t.Fatal(err)
		}
		kernel.Stop(id)
	}
	settle := func() int {
		time.Sleep(300 * time.Millisecond)
		runtime.GC()
		return runtime.NumGoroutine()
	}
	cycle()
	before := settle()
	for i := 0; i < 10; i++ {
		cycle()
	}
	if after := settle(); after > before+2 {
		t.Fatalf("10 次启停后协程从 %d 增至 %d", before, after)
	}
}

func TestInlineProviderRestartReleasesAdapters(t *testing.T) {
	for i := 0; i < 4; i++ {
		profile := packetProfile(9)
		profile["proxy-providers"] = map[string]any{"ecy-panel-nodes": map[string]any{"type": "inline", "payload": profile["proxies"]}}
		profile["proxies"] = []any{}
		profile["proxy-groups"] = []any{map[string]any{"name": "select", "type": "select", "use": []string{"ecy-panel-nodes"}}}
		id := startPacketCore(t, profile)
		if err := kernel.Select(id, "select", "synthetic"); err != nil {
			t.Fatal(err)
		}
		kernel.Stop(id)
	}
}

// 系统一次交来一批包：入队满时等内核取走，压力退回系统的包队列，不能丢包；停止时阻塞中的提交立即返回
func TestSubmitWaitsForQueueAndStopReleasesIt(t *testing.T) {
	id := startPacketCore(t, packetProfile(9))
	packet := make([]byte, 28+1200)
	packet[0], packet[8], packet[9] = 0x45, 64, 17
	binary.BigEndian.PutUint16(packet[2:], uint16(len(packet)))
	copy(packet[12:16], []byte{198, 18, 0, 2})
	copy(packet[16:20], []byte{192, 0, 2, 9})
	binary.BigEndian.PutUint16(packet[20:], 40000)
	binary.BigEndian.PutUint16(packet[22:], 9)
	binary.BigEndian.PutUint16(packet[24:], uint16(8+1200))
	for i := 0; i < 4096; i++ {
		if err := kernel.Submit(id, packet); err != nil {
			t.Fatalf("第 %d 个包：%v", i, err)
		}
	}
	released := make(chan error, 1)
	go func() {
		for {
			if err := kernel.Submit(id, packet); err != nil {
				released <- err
				return
			}
		}
	}()
	time.Sleep(100 * time.Millisecond)
	kernel.Stop(id)
	select {
	case err := <-released:
		if err != kernel.ErrStopped {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("停止后提交仍阻塞")
	}
}
