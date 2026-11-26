package bridgevalidation

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"ecycloud/apple/Kernel"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"github.com/metacubex/mipstack"
)

// 被测进程只有桥接内核，客户端协议栈、节点服务端与回显在另一个进程。变量：ECY_MEMORY_CONNECTIONS=200,500,1000，ECY_MEMORY_LIMIT_MIB=50，ECY_MEMORY_TLS=1，
// ECY_MEMORY_PROTO=trojan|vless|shadowsocks|anytls|hysteria2|tuic，ECY_MEMORY_STREAM_MIB 每条持续收发量，ECY_MEMORY_READ_KBPS 慢读速度，ECY_QUIC_WINDOW_MIB / ECY_QUIC_STREAM_MIB 窗口，ECY_RTT_MS 往返时延
func TestBridgeMemoryUnderConnections(t *testing.T) {
	switch os.Getenv("ECY_MEMORY_ROLE") {
	case "kernel":
		memoryKernelRole(t)
		return
	case "client":
		memoryClientRole(t)
		return
	}
	counts := os.Getenv("ECY_MEMORY_CONNECTIONS")
	if counts == "" {
		t.Skip("设置 ECY_MEMORY_CONNECTIONS 后才量测")
	}
	for _, field := range strings.Split(counts, ",") {
		n, err := strconv.Atoi(strings.TrimSpace(field))
		if err != nil || n <= 0 {
			t.Fatalf("连接数无效：%q", field)
		}
		command := exec.Command(os.Args[0], "-test.run=^TestBridgeMemoryUnderConnections$", "-test.count=1", "-test.v")
		command.Env = append(os.Environ(), "ECY_MEMORY_ROLE=kernel", "ECY_MEMORY_N="+strconv.Itoa(n))
		output, err := command.CombinedOutput()
		if err != nil {
			t.Fatalf("%d 条连接：%v\n%s", n, err, output)
		}
		for _, line := range strings.Split(string(output), "\n") {
			if strings.Contains(line, "MEMORY ") {
				t.Log(strings.TrimSpace(line[strings.Index(line, "MEMORY "):]))
			}
		}
	}
}

type memoryReading struct {
	heapInuse, stackInuse, resident, footprint uint64
	goroutines                                 int
}

func (m memoryReading) String() string {
	mib := func(v uint64) string { return fmt.Sprintf("%.1f", float64(v)/(1<<20)) }
	return fmt.Sprintf("heapInuse=%sMiB stackInuse=%sMiB goResident=%sMiB footprint=%sMiB goroutines=%d",
		mib(m.heapInuse), mib(m.stackInuse), mib(m.resident), mib(m.footprint), m.goroutines)
}

func readMemory() memoryReading {
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	return memoryReading{heapInuse: stats.HeapInuse, stackInuse: stats.StackInuse, resident: stats.Sys - stats.HeapReleased, footprint: physFootprint(), goroutines: runtime.NumGoroutine()}
}

func peak(a, b memoryReading) memoryReading {
	if b.footprint > a.footprint {
		a.footprint = b.footprint
	}
	if b.resident > a.resident {
		a.resident = b.resident
	}
	if b.heapInuse > a.heapInuse {
		a.heapInuse = b.heapInuse
	}
	if b.stackInuse > a.stackInuse {
		a.stackInuse = b.stackInuse
	}
	if b.goroutines > a.goroutines {
		a.goroutines = b.goroutines
	}
	return a
}

func writeFrame(w io.Writer, mu *sync.Mutex, packet []byte) error {
	mu.Lock()
	defer mu.Unlock()
	var size [2]byte
	binary.BigEndian.PutUint16(size[:], uint16(len(packet)))
	if _, err := w.Write(size[:]); err != nil {
		return err
	}
	_, err := w.Write(packet)
	return err
}

func readFrame(r *bufio.Reader, buffer []byte) ([]byte, error) {
	var size [2]byte
	if _, err := io.ReadFull(r, size[:]); err != nil {
		return nil, err
	}
	n := int(binary.BigEndian.Uint16(size[:]))
	if n > len(buffer) {
		return nil, io.ErrShortBuffer
	}
	_, err := io.ReadFull(r, buffer[:n])
	return buffer[:n], err
}

func memoryKernelRole(t *testing.T) {
	n, _ := strconv.Atoi(os.Getenv("ECY_MEMORY_N"))
	if limit, err := strconv.ParseUint(os.Getenv("ECY_MEMORY_LIMIT_MIB"), 10, 64); err == nil {
		kernel.SetTunnelMemoryLimit(limit << 20)
	}
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	local, remote := os.NewFile(uintptr(fds[0]), "kernel-packets"), os.NewFile(uintptr(fds[1]), "client-packets")
	child := exec.Command(os.Args[0], "-test.run=^TestBridgeMemoryUnderConnections$", "-test.count=1")
	child.Env = append(os.Environ(), "ECY_MEMORY_ROLE=client", "ECY_MEMORY_N="+strconv.Itoa(n))
	child.ExtraFiles = []*os.File{remote}
	child.Stderr = os.Stderr
	commands, _ := child.StdinPipe()
	events, _ := child.StdoutPipe()
	if err = child.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = child.Process.Kill(); _ = child.Wait() }()
	remote.Close()
	lines := bufio.NewScanner(events)
	next := func(prefix string) string {
		for lines.Scan() {
			if strings.HasPrefix(lines.Text(), prefix) {
				return strings.TrimSpace(strings.TrimPrefix(lines.Text(), prefix))
			}
		}
		t.Fatalf("客户端进程没有输出 %s", prefix)
		return ""
	}
	port, _ := strconv.Atoi(next("PORT "))
	profile := packetProfile(port)
	if os.Getenv("ECY_MEMORY_TLS") != "" {
		profile["proxies"] = []any{map[string]any{"name": "synthetic", "type": "socks5", "server": "127.0.0.1", "port": port, "udp": false, "tls": true, "skip-cert-verify": true}}
	}
	if proto := os.Getenv("ECY_MEMORY_PROTO"); proto != "" {
		profile["proxies"] = []any{protoProxy(proto, port)}
	}
	// ECY_MEMORY_GEODATA 指向含 geoip.metadb 与 GeoSite.dat 的目录时按面板规则加载 GEOSITE / GEOIP，基线更接近真实扩展
	if geodata := os.Getenv("ECY_MEMORY_GEODATA"); geodata != "" {
		profile["rules"] = []string{"GEOSITE,CN,DIRECT", "GEOIP,CN,DIRECT,no-resolve", "MATCH,select"}
		profile["geodata-mode"] = false
		profile["geo-auto-update"] = false
		directory := t.TempDir()
		if err = os.Chmod(directory, 0700); err != nil {
			t.Fatal(err)
		}
		if rules := os.Getenv("ECY_MEMORY_RULES"); rules != "" {
			templateRules(t, profile, directory, rules)
		}
		for _, name := range []string{"geoip.metadb", "GeoSite.dat"} {
			data, e := os.ReadFile(filepath.Join(geodata, name))
			if e != nil {
				t.Fatal(e)
			}
			if e = os.WriteFile(filepath.Join(directory, name), data, 0600); e != nil {
				t.Fatal(e)
			}
		}
		data, _ := json.Marshal(profile)
		started, e := kernel.Start(data, directory, 1500, "198.18.0.1/30", "fd00::1/126", "198.18.0.1:53")
		if e != nil {
			t.Fatal(e)
		}
		t.Cleanup(func() { kernel.Stop(started) })
		memoryForward(t, n, started, local, commands, next)
		return
	}
	memoryForward(t, n, startPacketCore(t, profile), local, commands, next)
}

// 测试地址在保留网段，面板模板里的 GEOIP,private 会把它们判成直连，所以不加
func templateRules(t *testing.T, profile map[string]any, directory, rules string) {
	files, err := filepath.Glob(filepath.Join(rules, "*.yaml"))
	if err != nil || len(files) == 0 {
		t.Fatalf("%s 下没有规则集", rules)
	}
	if err = os.Mkdir(filepath.Join(directory, "rules"), 0700); err != nil {
		t.Fatal(err)
	}
	providers := map[string]any{}
	groups := []any{map[string]any{"name": "select", "type": "select", "proxies": []string{"synthetic", "REJECT"}}}
	var list []string
	for _, file := range files {
		name := strings.TrimSuffix(filepath.Base(file), ".yaml")
		data, e := os.ReadFile(file)
		if e != nil {
			t.Fatal(e)
		}
		if e = os.WriteFile(filepath.Join(directory, "rules", name+".yaml"), data, 0600); e != nil {
			t.Fatal(e)
		}
		providers[name] = map[string]any{"type": "file", "behavior": "classical", "format": "yaml", "path": "./rules/" + name + ".yaml"}
		groups = append(groups, map[string]any{"name": "group-" + name, "type": "select", "proxies": []string{"select", "synthetic", "DIRECT"}})
		list = append(list, "RULE-SET,"+name+",group-"+name)
	}
	profile["rule-providers"] = providers
	profile["proxy-groups"] = groups
	profile["rules"] = append(list, "GEOSITE,CN,DIRECT", "GEOIP,CN,DIRECT", "MATCH,select")
	dns := profile["dns"].(map[string]any)
	dns["enhanced-mode"] = "fake-ip"
	dns["fake-ip-range"] = "198.18.0.1/16"
	dns["nameserver-policy"] = map[string]any{"geosite:cn": []string{"127.0.0.1:9"}}
	profile["sniffer"] = map[string]any{"enable": true, "sniff": map[string]any{"TLS": map[string]any{"ports": []int{443, 8443}}, "HTTP": map[string]any{"ports": []int{80, 8080}}, "QUIC": map[string]any{"ports": []int{443, 8443}}}}
	profile["tcp-concurrent"] = true
}

func memoryForward(t *testing.T, n int, id uint64, local *os.File, commands io.Writer, next func(string) string) {
	var writeMu sync.Mutex
	go func() {
		reader := bufio.NewReaderSize(local, 1<<16)
		buffer := make([]byte, kernel.MaximumPacketBytes)
		for {
			packet, e := readFrame(reader, buffer)
			if e != nil || kernel.Submit(id, packet) == kernel.ErrStopped {
				return
			}
		}
	}()
	go func() {
		buffer := make([]byte, kernel.MaximumPacketBytes)
		for {
			count, e := kernel.Read(id, buffer, time.Second)
			if e != nil {
				return
			}
			if count > 0 && writeFrame(local, &writeMu, buffer[:count]) != nil {
				return
			}
		}
	}()
	settle := func() memoryReading {
		time.Sleep(2 * time.Second)
		runtime.GC()
		return readMemory()
	}
	active := func() int {
		response, e := kernel.Control(id, []byte(`{"action":"snapshot","page":1,"scope":"active"}`))
		if e != nil {
			t.Fatal(e)
		}
		var snapshot struct{ Active int }
		_ = json.Unmarshal(response, &snapshot)
		return snapshot.Active
	}
	baseline := settle()
	fmt.Fprintln(commands, "OPEN")
	opened := next("OPENED ")
	idle := settle()
	alive := active()
	var traffic memoryReading
	sampling := make(chan struct{})
	sampled := make(chan memoryReading)
	// ReadMemStats 会暂停全部协程，只每 200 毫秒读一次；峰值只在一百毫秒内冒出，phys_footprint 另每 5 毫秒取一次
	go func() {
		var highest memoryReading
		next := time.Now()
		for {
			select {
			case <-sampling:
				sampled <- highest
				return
			case <-time.After(5 * time.Millisecond):
				highest.footprint = max(highest.footprint, physFootprint())
				if time.Now().After(next) {
					highest = peak(highest, readMemory())
					next = time.Now().Add(200 * time.Millisecond)
				}
			}
		}
	}()
	fmt.Fprintln(commands, "TRAFFIC")
	trafficStart := time.Now()
	moved := next("TRAFFIC ")
	fmt.Printf("MEMORY n=%d took=%dms\n", n, time.Since(trafficStart).Milliseconds())
	close(sampling)
	traffic = <-sampled
	after := settle()
	fmt.Printf("MEMORY n=%d opened=%s active=%d moved=%s\n", n, opened, alive, moved)
	for _, stage := range []struct {
		name    string
		reading memoryReading
	}{{"baseline", baseline}, {"idle", idle}, {"traffic-peak", traffic}, {"after", after}} {
		fmt.Printf("MEMORY n=%d %-12s %v\n", n, stage.name, stage.reading)
	}
	fmt.Fprintln(commands, "EXIT")
	kernel.Stop(id)
}

func memoryClientRole(t *testing.T) {
	n, _ := strconv.Atoi(os.Getenv("ECY_MEMORY_N"))
	link := os.NewFile(3, "packets")
	port := echoSocksProxy(t)
	if os.Getenv("ECY_MEMORY_TLS") != "" {
		port = echoSocksTLS(t)
	}
	if proto := os.Getenv("ECY_MEMORY_PROTO"); proto != "" {
		port = protoServer(t, proto, port)
	}
	if ms, _ := strconv.Atoi(os.Getenv("ECY_RTT_MS")); ms > 0 {
		port = delayRelay(t, port, time.Duration(ms)*time.Millisecond)
	}
	client, err := mipstack.New(mipstack.Config{MTU: 1500, LocalAddresses: []netip.Prefix{netip.MustParsePrefix("198.18.0.2/30")}, Routes: []mipstack.Route{{Destination: netip.MustParsePrefix("0.0.0.0/0")}}})
	if err != nil {
		t.Fatal(err)
	}
	if err = client.Start(); err != nil {
		t.Fatal(err)
	}
	var writeMu sync.Mutex
	go func() {
		buffers, sizes := [][]byte{make([]byte, 1500)}, make([]int, 1)
		for {
			count, e := client.Read(buffers, sizes, 0)
			if e != nil {
				return
			}
			for i := 0; i < count; i++ {
				if writeFrame(link, &writeMu, buffers[i][:sizes[i]]) != nil {
					return
				}
			}
		}
	}()
	go func() {
		reader := bufio.NewReaderSize(link, 1<<16)
		buffer := make([]byte, 1<<16)
		for {
			packet, e := readFrame(reader, buffer)
			if e != nil {
				return
			}
			if _, e = client.Write([][]byte{packet}, 0); e != nil {
				return
			}
		}
	}()
	fmt.Printf("PORT %d\n", port)
	commands := bufio.NewScanner(os.Stdin)
	connections := make([]net.Conn, 0, n)
	for commands.Scan() {
		switch commands.Text() {
		case "OPEN":
			var mu sync.Mutex
			var wg sync.WaitGroup
			gate := make(chan struct{}, 64)
			for i := 0; i < n; i++ {
				wg.Add(1)
				gate <- struct{}{}
				go func(i int) {
					defer wg.Done()
					defer func() { <-gate }()
					ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
					defer cancel()
					remote := netip.AddrPortFrom(netip.AddrFrom4([4]byte{192, 0, 2, byte(1 + i%200)}), uint16(8000+i/200))
					c, e := client.DialTCP(ctx, "tcp", netip.AddrPort{}, remote)
					if e != nil || !echoed(c, []byte("synthetic-open"), 60*time.Second) {
						return
					}
					mu.Lock()
					connections = append(connections, c)
					mu.Unlock()
				}(i)
			}
			wg.Wait()
			fmt.Printf("OPENED %d\n", len(connections))
		case "TRAFFIC":
			if mib, _ := strconv.Atoi(os.Getenv("ECY_MEMORY_STREAM_MIB")); mib > 0 {
				var moved atomic.Int64
				var wg sync.WaitGroup
				total := int64(mib) << 20
				for _, c := range connections {
					_ = c.SetDeadline(time.Time{})
					wg.Add(2)
					go func(c net.Conn) {
						defer wg.Done()
						chunk := make([]byte, 32<<10)
						for sent := int64(0); sent < total; sent += int64(len(chunk)) {
							if _, e := c.Write(chunk); e != nil {
								return
							}
						}
					}(c)
					go func(c net.Conn) {
						defer wg.Done()
						rate, _ := strconv.Atoi(os.Getenv("ECY_MEMORY_READ_KBPS"))
						if rate <= 0 {
							n, _ := io.CopyN(io.Discard, c, total)
							moved.Add(n)
							return
						}
						buf := make([]byte, 32<<10)
						began := time.Now()
						var got int64
						for got < total {
							n, e := c.Read(buf)
							got += int64(n)
							if e != nil {
								break
							}
							if ahead := time.Duration(float64(got)/float64(rate*1024)*float64(time.Second)) - time.Since(began); ahead > 0 {
								time.Sleep(ahead)
							}
						}
						moved.Add(got)
					}(c)
				}
				wg.Wait()
				fmt.Printf("TRAFFIC %dMiB\n", moved.Load()>>20)
				continue
			}
			var moved atomic.Int64
			var wg sync.WaitGroup
			payload := make([]byte, 64*1024)
			for _, c := range connections {
				wg.Add(1)
				go func(c net.Conn) {
					defer wg.Done()
					for round := 0; round < 4; round++ {
						if !echoed(c, payload, 60*time.Second) {
							return
						}
						moved.Add(int64(len(payload)))
					}
				}(c)
			}
			wg.Wait()
			fmt.Printf("TRAFFIC %dMiB\n", moved.Load()>>20)
		case "EXIT":
			return
		}
	}
}

func echoSocksProxy(t *testing.T) int {
	t.Helper()
	proxy, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	return echoSocksOn(t, proxy)
}

// 出站套一层 TLS，每条连接多出加密协议的缓冲，与 Trojan、VLESS-TLS 这类节点相近
func echoSocksTLS(t *testing.T) int {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "synthetic.example.test"}, DNSNames: []string{"synthetic.example.test"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	proxy, err := tls.Listen("tcp4", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}})
	if err != nil {
		t.Fatal(err)
	}
	return echoSocksOn(t, proxy)
}

func echoSocksOn(t *testing.T, proxy net.Listener) int {
	t.Cleanup(func() { _ = proxy.Close() })
	go func() {
		for {
			c, e := proxy.Accept()
			if e != nil {
				return
			}
			go func() {
				defer c.Close()
				head := make([]byte, 2)
				if _, e := io.ReadFull(c, head); e != nil {
					return
				}
				if _, e := io.CopyN(io.Discard, c, int64(head[1])); e != nil {
					return
				}
				_, _ = c.Write([]byte{5, 0})
				request := make([]byte, 4)
				if _, e := io.ReadFull(c, request); e != nil || request[3] != 1 {
					return
				}
				if _, e := io.CopyN(io.Discard, c, 6); e != nil {
					return
				}
				_, _ = c.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 1})
				_, _ = io.Copy(c, c)
			}()
		}
	}()
	return proxy.Addr().(*net.TCPAddr).Port
}

func echoed(c net.Conn, payload []byte, timeout time.Duration) bool {
	_ = c.SetDeadline(time.Now().Add(timeout))
	sent := make(chan error, 1)
	go func() { _, e := c.Write(payload); sent <- e }()
	echo := make([]byte, len(payload))
	_, e := io.ReadFull(c, echo)
	return e == nil && <-sent == nil
}

func tunnelDial(client *mipstack.Stack, index int) net.Conn {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	remote := netip.AddrPortFrom(netip.AddrFrom4([4]byte{192, 0, 2, byte(1 + index%200)}), uint16(8000+index/200))
	c, err := client.DialTCP(ctx, "tcp", netip.AddrPort{}, remote)
	if err != nil {
		return nil
	}
	if !echoed(c, []byte("synthetic"), 10*time.Second) {
		_ = c.Close()
		return nil
	}
	return c
}

// 内存余量不足时新 TCP 连接被重置，余量恢复后又能新建
func TestPacketTunnelRefusesConnectionsWhenMemoryIsTight(t *testing.T) {
	id := startPacketCore(t, packetProfile(echoSocksProxy(t)))
	client := packetClient(t, id)
	t.Cleanup(func() { kernel.SetTunnelMemoryLimit(0) })
	first := tunnelDial(client, 0)
	if first == nil {
		t.Fatal("不限内存时连接没有建立")
	}
	_ = first.Close()
	kernel.SetTunnelMemoryLimit(1)
	if c := tunnelDial(client, 1); c != nil {
		_ = c.Close()
		t.Fatal("内存余量不足时仍接受新连接")
	}
	kernel.SetTunnelMemoryLimit(0)
	if c := tunnelDial(client, 2); c == nil {
		t.Fatal("内存恢复后仍无法新建连接")
	} else {
		_ = c.Close()
	}
}

// 逼近上限时从最新的连接起断开，早先建立的长连接保留
func TestPacketTunnelShedsNewestConnectionsFirst(t *testing.T) {
	startPacketCore(t, packetProfile(9))
	trackers := make([]*syntheticTracker, 16)
	for i := range trackers {
		trackers[i] = &syntheticTracker{id: fmt.Sprintf("shed-%02d", i), info: statistic.TrackerInfo{Metadata: &C.Metadata{NetWork: C.TCP}, Start: time.Now().Add(time.Duration(i-len(trackers)) * time.Minute)}}
		statistic.DefaultManager.Join(trackers[i])
	}
	t.Cleanup(func() {
		kernel.SetTunnelMemoryLimit(0)
		for _, c := range trackers {
			_ = c.Close()
		}
	})
	kernel.SetTunnelMemoryLimit(1)
	deadline := time.Now().Add(5 * time.Second)
	for statistic.DefaultManager.Get(trackers[len(trackers)-1].id) != nil {
		if time.Now().After(deadline) {
			t.Fatal("内存逼近上限时没有断开连接")
		}
		time.Sleep(10 * time.Millisecond)
	}
	kernel.SetTunnelMemoryLimit(0)
	closed := 0
	for i, c := range trackers {
		if statistic.DefaultManager.Get(c.id) == nil {
			closed++
		} else if closed > 0 {
			t.Fatalf("先断开了较早的连接：第 %d 条之前已有连接被断开", i+1)
		}
	}
	if closed == 0 || closed == len(trackers) {
		t.Fatalf("断开了 %d / %d 条", closed, len(trackers))
	}
}
