package bridgevalidation

import (
	"ecycloud/apple/Kernel"
	"encoding/json"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/geodata/router"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"google.golang.org/protobuf/proto"
)

func startGeoSiteCore(t *testing.T, profile map[string]any) uint64 {
	t.Helper()
	sites, err := proto.Marshal(&router.GeoSiteList{Entry: []*router.GeoSite{
		{CountryCode: "CN", Domain: []*router.Domain{{Type: router.Domain_Domain, Value: "example.cn"}, {Type: router.Domain_Full, Value: "full.example.test"}}},
		{CountryCode: "MIXED", Domain: []*router.Domain{{Type: router.Domain_Domain, Value: "example.cn"}, {Type: router.Domain_Plain, Value: "keyword"}}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	if err = os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(directory, "GeoSite.dat"), sites, 0600); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	id, err := kernel.Start(data, directory, 1500, "198.18.0.1/30", "fd00::1/126", "198.18.0.1:53")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { kernel.Stop(id) })
	return id
}

// 包隧道里 GEOSITE 换成同内容的域名规则集：后缀、完整域名的命中与原列表一致，连接与日志仍显示 GeoSite(列表名)
func TestPacketTunnelReplacesGeoSiteWithEquivalentRuleSet(t *testing.T) {
	profile := packetProfile(echoSocksProxy(t))
	profile["rules"] = []string{"GEOSITE,CN,select", "MATCH,REJECT"}
	profile["dns"].(map[string]any)["nameserver-policy"] = map[string]any{"geosite:cn": []string{"127.0.0.1:9"}}
	profile["sniffer"] = map[string]any{"enable": true, "override-destination": false, "sniff": map[string]any{"HTTP": map[string]any{"ports": []int{80}}}}
	id := startGeoSiteCore(t, profile)
	rules := tunnel.Rules()
	if len(rules) != 2 || rules[0].RuleType() != C.RuleSet {
		t.Fatalf("GEOSITE 没有换成规则集：%v", rules)
	}
	for host, want := range map[string]bool{"example.cn": true, "www.example.cn": true, "full.example.test": true, "sub.full.example.test": false, "example.com": false, "notexample.cn": false} {
		if matched, _ := rules[0].Match(&C.Metadata{Host: host}, C.RuleMatchHelper{}); matched != want {
			t.Errorf("%s：命中 %v，应为 %v", host, matched, want)
		}
	}
	client := packetClient(t, id)
	conn := tunnelDial(client, 0)
	if conn != nil {
		_ = conn.Close()
		t.Fatal("没有域名的连接不该命中 GEOSITE")
	}
	request := []byte("GET / HTTP/1.1\r\nHost: www.example.cn\r\n\r\n")
	c, err := client.DialTCP(t.Context(), "tcp", netip.AddrPort{}, netip.MustParseAddrPort("192.0.2.9:80"))
	if err != nil || !echoed(c, request, 10*time.Second) {
		t.Fatalf("按嗅探到的域名命中后连接不通：%v", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	var snapshot struct {
		Connections []struct{ Rule, RulePayload string }
	}
	shown := false
	for deadline := time.Now().Add(5 * time.Second); !shown && time.Now().Before(deadline); time.Sleep(100 * time.Millisecond) {
		data, err := kernel.Control(id, []byte(`{"action":"snapshot","page":1,"scope":"active"}`))
		if err != nil || json.Unmarshal(data, &snapshot) != nil {
			t.Fatalf("snapshot failed: %v", err)
		}
		for _, c := range snapshot.Connections {
			if c.Rule == C.RuleSet.String() {
				t.Fatalf("连接露出了改写后的规则集：%+v", c)
			}
			shown = shown || c.Rule == "GeoSite" && c.RulePayload == "CN"
		}
	}
	if !shown {
		t.Fatalf("连接显示的规则：%+v", snapshot.Connections)
	}
	var logs struct{ Entries []struct{ Message string } }
	data, err := kernel.Control(id, []byte(`{"action":"logs","page":1,"query":"match"}`))
	if err != nil || json.Unmarshal(data, &logs) != nil {
		t.Fatalf("logs failed: %v", err)
	}
	shown = false
	for _, entry := range logs.Entries {
		if strings.Contains(entry.Message, "ecy-geosite") {
			t.Fatalf("日志露出了改写后的规则集名：%s", entry.Message)
		}
		shown = shown || strings.Contains(entry.Message, "match GeoSite(CN) using")
	}
	if !shown {
		t.Fatalf("日志里没有 GeoSite(CN) 的命中记录：%+v", logs.Entries)
	}
}

// 列表里有关键字、正则时规则集表达不了，原样保留 GEOSITE
func TestPacketTunnelKeepsGeoSiteThatRuleSetsCannotExpress(t *testing.T) {
	profile := packetProfile(9)
	profile["rules"] = []string{"GEOSITE,cn,DIRECT", "GEOSITE,mixed,DIRECT", "MATCH,select"}
	startGeoSiteCore(t, profile)
	for _, rule := range tunnel.Rules()[:2] {
		if rule.RuleType() != C.GEOSITE {
			t.Fatalf("部分改写会让启动校验照样装入原始表：%v", tunnel.Rules())
		}
	}
}
