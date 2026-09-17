package mihomo

import (
	"context"
	"encoding/json"
	"net/netip"
	"testing"

	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/component/resolver"
	D "github.com/miekg/dns"
)

func TestStartPreservesFakeIPAfterValidationAndRestart(t *testing.T) {
	Setup(t.TempDir())
	t.Cleanup(func() {
		Stop()
		if err := cachefile.Cache().Close(); err != nil {
			t.Error(err)
		}
	})
	config := map[string]any{
		"mode":              "rule",
		"find-process-mode": "off",
		"profile":           map[string]any{"store-fake-ip": true},
		"dns": map[string]any{
			"enable":        true,
			"enhanced-mode": "fake-ip",
			"fake-ip-range": "198.18.0.1/16",
			"nameserver":    []string{"127.0.0.1:1"},
		},
		"rules": []string{"MATCH,REJECT"},
	}
	raw, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := Start(string(raw), 0); err != nil {
		t.Fatal(err)
	}
	lookup := func(host string) netip.Addr {
		t.Helper()
		msg := new(D.Msg)
		msg.SetQuestion(host+".", D.TypeA)
		answer, err := resolver.ServeMsg(context.Background(), msg)
		if err != nil {
			t.Fatal(err)
		}
		if len(answer.Answer) != 1 {
			t.Fatalf("DNS 答案数量：%d", len(answer.Answer))
		}
		ip, ok := netip.AddrFromSlice(answer.Answer[0].(*D.A).A)
		if !ok {
			t.Fatal("无效虚拟地址")
		}
		return ip.Unmap()
	}
	oldIP := lookup("alpha.example.invalid")
	config["profile"] = map[string]any{"store-fake-ip": false}
	validation, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := Check(string(validation)); err != nil {
		t.Fatal(err)
	}
	if host, ok := resolver.FindHostByIP(oldIP); !ok || host != "alpha.example.invalid" {
		t.Fatalf("校验改变了旧地址映射：%q, %v", host, ok)
	}
	if err := Start(string(raw), 0); err != nil {
		t.Fatal(err)
	}
	newIP := lookup("beta.example.invalid")
	if oldIP == newIP {
		t.Fatalf("重启后地址被复用：%s", oldIP)
	}
	if host, ok := resolver.FindHostByIP(oldIP); !ok || host != "alpha.example.invalid" {
		t.Fatalf("重启改变了旧地址映射：%q, %v", host, ok)
	}
}
