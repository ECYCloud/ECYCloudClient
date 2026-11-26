package bridgevalidation

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/metacubex/mihomo/hub/executor"
)

const protoUUID = "b831381d-6324-4d53-ad4f-8cda48b30811"
const protoPassword = "synthetic-password"

func freePort(t *testing.T, udp bool) int {
	if udp {
		c, err := net.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		return c.LocalAddr().(*net.UDPAddr).Port
	}
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func protoCert(t *testing.T) (string, string) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "synthetic.example.test"}, DNSNames: []string{"synthetic.example.test"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, _ := x509.MarshalECPrivateKey(key)
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})), string(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}))
}

// 客户端进程里用 mihomo 起对应协议的服务端，出站转给回显 SOCKS5；ECY_QUIC_WINDOW_MIB 限制 Hysteria2 / TUIC 的接收窗口
func protoServer(t *testing.T, proto string, echo int) int {
	cert, key := protoCert(t)
	port := freePort(t, proto == "hysteria2" || proto == "tuic")
	listener := map[string]any{"name": "server", "type": proto, "listen": "127.0.0.1", "port": port}
	switch proto {
	case "trojan":
		listener["users"] = []any{map[string]any{"username": "u", "password": protoPassword}}
		listener["certificate"], listener["private-key"] = cert, key
	case "vless":
		listener["users"] = []any{map[string]any{"username": "u", "uuid": protoUUID}}
		listener["certificate"], listener["private-key"] = cert, key
	case "shadowsocks":
		listener["cipher"], listener["password"] = "aes-128-gcm", protoPassword
	case "hysteria2", "anytls":
		listener["users"] = map[string]string{"u": protoPassword}
		listener["certificate"], listener["private-key"] = cert, key
	case "tuic":
		listener["users"] = map[string]string{protoUUID: protoPassword}
		listener["certificate"], listener["private-key"] = cert, key
		listener["congestion-controller"] = "bbr"
	}
	config, _ := json.Marshal(map[string]any{"mode": "rule", "log-level": "silent", "ipv6": false, "listeners": []any{listener},
		"proxies": []any{map[string]any{"name": "echo", "type": "socks5", "server": "127.0.0.1", "port": echo}}, "rules": []string{"MATCH,echo"}, "dns": map[string]any{"enable": false}})
	cfg, err := executor.ParseWithBytes(config)
	if err != nil {
		t.Fatal(err)
	}
	executor.ApplyConfig(cfg, true)
	return port
}

func protoProxy(proto string, port int) map[string]any {
	base := map[string]any{"name": "synthetic", "server": "127.0.0.1", "port": port, "udp": false, "skip-cert-verify": true, "sni": "synthetic.example.test"}
	switch proto {
	case "trojan":
		base["type"], base["password"] = "trojan", protoPassword
	case "vless":
		base["type"], base["uuid"], base["tls"], base["servername"] = "vless", protoUUID, true, "synthetic.example.test"
		delete(base, "sni")
	case "shadowsocks":
		base["type"], base["cipher"], base["password"] = "ss", "aes-128-gcm", protoPassword
		delete(base, "sni")
		delete(base, "skip-cert-verify")
	case "hysteria2":
		base["type"], base["password"] = "hysteria2", protoPassword
		if w, _ := strconv.Atoi(os.Getenv("ECY_QUIC_WINDOW_MIB")); w > 0 {
			base["max-connection-receive-window"], base["initial-connection-receive-window"] = w<<20, w<<20
			stream := w << 19
			if m, _ := strconv.Atoi(os.Getenv("ECY_QUIC_STREAM_MIB")); m > 0 {
				stream = m << 20
			}
			base["max-stream-receive-window"], base["initial-stream-receive-window"] = stream, stream
		}
	case "tuic":
		base["type"], base["uuid"], base["password"], base["alpn"] = "tuic", protoUUID, protoPassword, []string{"h3"}
		if w, _ := strconv.Atoi(os.Getenv("ECY_QUIC_WINDOW_MIB")); w > 0 {
			base["recv-window"], base["recv-window-conn"] = w<<20, w<<19
		}
	case "anytls":
		base["type"], base["password"] = "anytls", protoPassword
	}
	return base
}
