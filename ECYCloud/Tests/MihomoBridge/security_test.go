package bridgevalidation

import (
	"ecycloud/apple/Kernel"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
)

func checksum(b []byte) uint16 {
	var n uint32
	for len(b) > 1 {
		n += uint32(binary.BigEndian.Uint16(b))
		b = b[2:]
	}
	if len(b) > 0 {
		n += uint32(b[0]) << 8
	}
	for n>>16 > 0 {
		n = n&65535 + n>>16
	}
	return ^uint16(n)
}
func TestOfficialPacketBridgeUDP(t *testing.T) {
	C.SetHomeDir(t.TempDir())
	echo, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	proxy, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()
	go func() {
		c, e := proxy.Accept()
		if e != nil {
			return
		}
		defer c.Close()
		_ = c.SetDeadline(time.Now().Add(10 * time.Second))
		head := make([]byte, 2)
		if _, e = io.ReadFull(c, head); e != nil {
			return
		}
		methods := make([]byte, int(head[1]))
		if _, e = io.ReadFull(c, methods); e != nil {
			return
		}
		_, _ = c.Write([]byte{5, 0})
		req := make([]byte, 10)
		if _, e = io.ReadFull(c, req); e != nil {
			return
		}
		reply := []byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 0}
		binary.BigEndian.PutUint16(reply[8:], uint16(echo.LocalAddr().(*net.UDPAddr).Port))
		_, _ = c.Write(reply)
		_, _ = io.Copy(io.Discard, c)
	}()
	go func() {
		b := make([]byte, 1500)
		n, a, e := echo.ReadFrom(b)
		if e == nil {
			_, _ = echo.WriteTo(b[:n], a)
		}
	}()
	config := fmt.Sprintf(`{"mixed-port":0,"port":0,"socks-port":0,"allow-lan":false,"external-controller":"","mode":"rule","log-level":"silent","dns":{"enable":false},"tun":{"enable":false},"proxies":[{"name":"synthetic","type":"socks5","server":"127.0.0.1","port":%d,"udp":true}],"proxy-groups":[],"rules":["MATCH,synthetic"],"profile":{"store-selected":false,"store-fake-ip":false}}`, proxy.Addr().(*net.TCPAddr).Port)
	var profile map[string]any
	if err := json.Unmarshal([]byte(config), &profile); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"mixed-port", "port", "socks-port", "redir-port", "tproxy-port"} {
		profile[key] = 0
	}
	for _, key := range []string{"external-controller", "external-controller-unix", "external-controller-pipe", "external-controller-tls", "external-ui", "external-ui-url", "external-doh-server", "ss-config", "vmess-config"} {
		profile[key] = ""
	}
	profile["listeners"] = []any{}
	profile["tunnels"] = []any{}
	profile["tuic-server"] = map[string]bool{"enable": false}
	profile["iptables"] = map[string]bool{"enable": false}
	data, _ := json.Marshal(profile)
	directory := t.TempDir()
	if err := os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	id, err := kernel.Start(data, directory, 1500, "198.18.0.1/30", "", "198.18.0.1:53")
	if err != nil {
		t.Fatal(err)
	}
	defer kernel.Stop(id)
	payload := []byte("synthetic-packet-bridge")
	packet := make([]byte, 28+len(payload))
	packet[0] = 0x45
	binary.BigEndian.PutUint16(packet[2:4], uint16(len(packet)))
	packet[8] = 64
	packet[9] = 17
	copy(packet[12:16], []byte{198, 18, 0, 2})
	copy(packet[16:20], []byte{192, 0, 2, 1})
	binary.BigEndian.PutUint16(packet[10:12], checksum(packet[:20]))
	binary.BigEndian.PutUint16(packet[20:22], 14001)
	binary.BigEndian.PutUint16(packet[22:24], 8888)
	binary.BigEndian.PutUint16(packet[24:26], uint16(8+len(payload)))
	copy(packet[28:], payload)
	if err = kernel.Submit(id, packet); err != nil {
		t.Fatal(err)
	}
	result := make([]byte, kernel.MaximumPacketBytes)
	n, err := kernel.Read(id, result, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	result = result[:n]
	if len(result) < 28 || string(result[28:]) != string(payload) {
		t.Fatalf("unexpected packet length/protocol: %d", len(result))
	}
	if result[9] != 17 || binary.BigEndian.Uint16(result[22:24]) != 14001 {
		t.Fatal("unexpected UDP reply")
	}
	// Read must unblock on stop, and old handles must never reach a restarted session.
	done := make(chan error, 1)
	go func() { _, e := kernel.Read(id, make([]byte, kernel.MaximumPacketBytes), time.Minute); done <- e }()
	kernel.Stop(id)
	select {
	case e := <-done:
		if e != kernel.ErrStopped {
			t.Fatal(e)
		}
	case <-time.After(time.Second):
		t.Fatal("stop did not unblock reader")
	}
	if kernel.Submit(id, packet) != kernel.ErrStopped {
		t.Fatal("old session accepted packet")
	}
	next, err := kernel.Start(data, directory, 1500, "198.18.0.1/30", "", "198.18.0.1:53")
	if err != nil {
		t.Fatal(err)
	}
	defer kernel.Stop(next)
	kernel.Stop(id)
	if next == id || kernel.Submit(next, []byte{0x45}) != kernel.ErrPacket {
		t.Fatal("restart generation or packet validation failed")
	}

}

func TestAssembledConfiguration(t *testing.T) {
	path := os.Getenv("ECY_SYNTHETIC_CONFIG")
	if path == "" {
		t.Skip("需提供 Swift 生成的虚构校验配置")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	C.SetHomeDir(t.TempDir())
	validated, err := executor.ParseWithBytes(data)
	if err != nil {
		t.Fatalf("官方 mihomo 拒绝虚构配置：%v", err)
	}
	// 纯校验也会创建代理对象；在下次装配前释放，不能留给并发运行的终结器。
	for _, proxy := range validated.Proxies {
		_ = proxy.Adapter().Close()
	}
	for _, provider := range validated.Providers {
		for _, proxy := range provider.Proxies() {
			_ = proxy.Adapter().Close()
		}
		if closer, ok := provider.(io.Closer); ok {
			_ = closer.Close()
		}
	}
	for _, provider := range validated.RuleProviders {
		if closer, ok := provider.(io.Closer); ok {
			_ = closer.Close()
		}
	}
	packet, err := os.ReadFile(path + ".packet")
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	if err = os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	id, err := kernel.Start(packet, directory, 1500, "172.19.0.1/30", "fdfe:dcba:9876::1/126", "172.19.0.2:53")
	if err != nil {
		t.Fatal("Swift 装配的配置不能启动生产桥接：", err)
	}
	kernel.Stop(id)
	standby, err := kernel.Start(packet, directory, 0, "", "", "")
	if err != nil {
		t.Fatal("Swift 装配的配置不能启动待机桥接：", err)
	}
	kernel.Stop(standby)
}
