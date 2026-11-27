package bridgevalidation

import (
	"bytes"
	"ecycloud/apple/Kernel"
	"encoding/json"
	"fmt"
	"github.com/metacubex/mihomo/component/geodata/router"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"google.golang.org/protobuf/proto"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestStandbyControlDoesNotCreatePacketDeviceAndCanRestartAsVPN(t *testing.T) {
	data, err := json.Marshal(packetProfile(9))
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	if err := os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	id, err := kernel.Start(data, directory, 0, "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { kernel.Stop(id) })
	for _, command := range []string{
		`{"action":"snapshot","page":1}`,
		`{"action":"select","group":"select","node":"REJECT"}`,
		`{"action":"probe","node":"REJECT","scope":"delay"}`,
	} {
		if _, err := kernel.Control(id, []byte(command)); err != nil {
			t.Fatal(err)
		}
	}
	if err := kernel.Submit(id, make([]byte, 40)); err != kernel.ErrStopped {
		t.Fatalf("standby accepted packets: %v", err)
	}
	if _, err := kernel.Read(id, make([]byte, kernel.MaximumPacketBytes), time.Millisecond); err != kernel.ErrStopped {
		t.Fatalf("standby created packet output: %v", err)
	}
	if _, err := kernel.Start(data, directory, 1500, "198.18.0.1/30", "", "198.18.0.1:53"); err != kernel.ErrBusy {
		t.Fatalf("parallel core accepted: %v", err)
	}
	kernel.Stop(id)
	vpn := startPacketCore(t, packetProfile(9))
	if vpn == id {
		t.Fatal("reused old runtime identity")
	}
	if _, err := kernel.Control(id, []byte(`{"action":"snapshot","page":1}`)); err != kernel.ErrStopped {
		t.Fatal("old standby retained control")
	}
}

func TestLiveControlUsesOfficialStateAndRejectsOldSession(t *testing.T) {
	id := startPacketCore(t, packetProfile(9))
	statistic.DefaultManager.PushUploaded(1234)
	statistic.DefaultManager.PushDownloaded(5678)
	data, err := kernel.Control(id, []byte(`{"action":"snapshot","page":1}`))
	if err != nil {
		t.Fatal(err)
	}
	var snapshot struct {
		UploadTotal   int64
		DownloadTotal int64
		Selections    map[string]string
		Connections   []any
		Total         int
	}
	// 首页流量与 Flutter 一致只计走代理的连接，内核全量计数不进入快照
	if json.Unmarshal(data, &snapshot) != nil || snapshot.UploadTotal != 0 || snapshot.DownloadTotal != 0 || snapshot.Selections["select"] != "synthetic" || snapshot.Connections == nil || snapshot.Total != 0 {
		t.Fatalf("unexpected statistics: %s", data)
	}
	if _, err = kernel.Control(id, []byte(`{"action":"select","group":"select","node":"REJECT"}`)); err != nil {
		t.Fatal(err)
	}
	data, _ = kernel.Control(id, []byte(`{"action":"snapshot","page":1}`))
	_ = json.Unmarshal(data, &snapshot)
	if snapshot.Selections["select"] != "REJECT" {
		t.Fatal("selection did not come from core")
	}
	for _, request := range []string{`{"action":"snapshot","page":0}`, `{"action":"logs","page":101}`, `{"action":"select","group":"select","node":"unknown"}`, `{"action":"close"}`, `{"action":"unexpected"}`, strings.Repeat("x", 4097)} {
		if _, err := kernel.Control(id, []byte(request)); err == nil {
			t.Fatalf("accepted invalid request %q", request[:min(60, len(request))])
		}
	}
	kernel.Stop(id)
	if _, err := kernel.Control(id, []byte(`{"action":"snapshot","page":1}`)); err != kernel.ErrStopped {
		t.Fatalf("old session accepted: %v", err)
	}
}

func TestSnapshotCountsOnlyProxyTrafficAndDrainsRank(t *testing.T) {
	id := startPacketCore(t, packetProfile(9))
	type rankSnapshot struct {
		UploadTotal, DownloadTotal int64
		Rank                       struct{ Groups, Hosts map[string]int64 }
	}
	read := func() rankSnapshot {
		t.Helper()
		data, err := kernel.Control(id, []byte(`{"action":"snapshot","page":1}`))
		var snapshot rankSnapshot
		if err != nil || json.Unmarshal(data, &snapshot) != nil {
			t.Fatalf("snapshot failed: %v", err)
		}
		return snapshot
	}
	read()
	trackers := []*syntheticTracker{}
	for _, item := range []struct {
		id, host string
		chain    C.Chain
		up, down int64
	}{
		{"proxied", "video.example.test", C.Chain{"synthetic", "select"}, 100, 900},
		{"direct", "direct.example.test", C.Chain{"DIRECT"}, 5000, 5000},
		{"server", "127.0.0.1", C.Chain{"synthetic", "select"}, 10, 0},
	} {
		c := &syntheticTracker{id: item.id, info: statistic.TrackerInfo{Metadata: &C.Metadata{Host: item.host, NetWork: C.TCP}, Chain: item.chain, Start: time.Now()}}
		c.info.UploadTotal.Store(item.up)
		c.info.DownloadTotal.Store(item.down)
		statistic.DefaultManager.Join(c)
		trackers = append(trackers, c)
	}
	t.Cleanup(func() {
		for _, c := range trackers {
			_ = c.Close()
		}
	})
	snapshot := read()
	if snapshot.UploadTotal != 110 || snapshot.DownloadTotal != 900 {
		t.Fatalf("direct traffic counted: %+v", snapshot)
	}
	if snapshot.Rank.Groups["select"] != 1010 || snapshot.Rank.Hosts["video.example.test"] != 1000 || len(snapshot.Rank.Hosts) != 1 {
		t.Fatalf("unexpected rank: %+v", snapshot.Rank)
	}
	if snapshot = read(); len(snapshot.Rank.Groups) != 0 || len(snapshot.Rank.Hosts) != 0 || snapshot.UploadTotal != 110 {
		t.Fatalf("rank was not drained: %+v", snapshot)
	}
}

func TestNodeProbesRejectInvalidTargetsAndDoNotBlockControl(t *testing.T) {
	id := startPacketCore(t, packetProfile(9))
	for _, request := range []string{
		`{"action":"probe","node":"DIRECT","scope":"speed"}`,
		`{"action":"probe","node":"missing","scope":"delay"}`,
		`{"action":"probe","node":"REJECT","scope":"unknown"}`,
		`{"action":"probes","node":"REJECT","scope":"delay"}`,
	} {
		if _, err := kernel.Control(id, []byte(request)); err == nil {
			t.Fatal("accepted invalid probe")
		}
	}
	if _, err := kernel.Control(id, []byte(`{"action":"probe","node":"REJECT","scope":"delay"}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := kernel.Control(id, []byte(`{"action":"snapshot","page":1}`)); err != nil {
		t.Fatal("probe blocked control", err)
	}
	deadline := time.Now().Add(time.Second)
	finished := false
	for time.Now().Before(deadline) {
		data, err := kernel.Control(id, []byte(`{"action":"probes","node":"REJECT","scope":"delay"}`))
		if err != nil {
			t.Fatal(err)
		}
		var result struct {
			Running, Failed bool
			Delay           int
		}
		if err := json.Unmarshal(data, &result); err != nil {
			t.Fatal(err)
		}
		if !result.Running {
			if !result.Failed || result.Delay != 0 {
				t.Fatal("REJECT returned a usable latency")
			}
			finished = true
			break
		}
		time.Sleep(time.Millisecond)
	}
	if !finished {
		t.Fatal("local rejection did not finish")
	}
	if _, err := kernel.Control(id, []byte(`{"action":"probe","node":"REJECT","scope":"delay"}`)); err != nil {
		t.Fatal(err)
	}
	kernel.Stop(id)
	if _, err := kernel.Control(id, []byte(`{"action":"probes","node":"REJECT","scope":"delay"}`)); err != kernel.ErrStopped {
		t.Fatal("stopped lease retained probe access")
	}
}

// geox-url 下载不接受取消，单个文件最长 90 秒；断开不能被一次进行中的 GeoData 更新拖住
func TestStopDoesNotWaitForGeoDataDownload(t *testing.T) {
	stalled, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	accepted := make(chan net.Conn, 8)
	go func() {
		for {
			conn, err := stalled.Accept()
			if err != nil {
				return
			}
			accepted <- conn
		}
	}()
	t.Cleanup(func() {
		stalled.Close()
		for len(accepted) > 0 {
			(<-accepted).Close()
		}
	})
	sites, err := proto.Marshal(&router.GeoSiteList{Entry: []*router.GeoSite{{
		CountryCode: "CN", Domain: []*router.Domain{{Type: router.Domain_Full, Value: "synthetic.example.test"}},
	}}})
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	if err := os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "GeoSite.dat"), sites, 0600); err != nil {
		t.Fatal(err)
	}
	// geox-url 只收 https：卡在 TLS 握手同样是一次停滞的下载
	base := "https://" + stalled.Addr().String() + "/"
	profile := packetProfile(9)
	profile["rules"] = []string{"GEOSITE,cn,DIRECT", "MATCH,DIRECT"}
	profile["geox-url"] = map[string]string{"geosite": base + "GeoSite.dat", "geoip": base + "geoip.dat", "mmdb": base + "geoip.metadb", "asn": base + "asn.mmdb"}
	data, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	id, err := kernel.Start(data, directory, 0, "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { kernel.Stop(id) })
	if _, err := kernel.Control(id, []byte(`{"action":"geodata"}`)); err != nil {
		t.Fatal(err)
	}
	select {
	case conn := <-accepted:
		accepted <- conn
	case <-time.After(5 * time.Second):
		t.Fatal("GeoData 更新没有开始下载")
	}
	stopped := make(chan struct{})
	go func() {
		kernel.Stop(id)
		close(stopped)
	}()
	select {
	case <-stopped:
	case <-time.After(5 * time.Second):
		t.Fatal("断开被进行中的 GeoData 下载阻塞")
	}
}

// 包隧道实例跑在系统 VPN 扩展里：重新下载会整份解码 GeoSite，堆瞬时涨到扩展被系统终止，只有待机内核受理
func TestPacketTunnelRefusesGeoDataUpdate(t *testing.T) {
	id := startPacketCore(t, packetProfile(9))
	for _, command := range []string{`{"action":"geodata"}`, `{"action":"geodata","scope":"status"}`} {
		if _, err := kernel.Control(id, []byte(command)); err != kernel.ErrGeoDataInTunnel {
			t.Fatalf("%s: %v", command, err)
		}
	}
}

type syntheticTracker struct {
	C.Connection
	id   string
	info statistic.TrackerInfo
}

func (c *syntheticTracker) ID() string                   { return c.id }
func (c *syntheticTracker) Info() *statistic.TrackerInfo { return &c.info }
func (c *syntheticTracker) Close() error                 { statistic.DefaultManager.Leave(c); return nil }

func TestSelectingNodeClosesOnlyConnectionsThroughPreviousOutbound(t *testing.T) {
	id := startPacketCore(t, packetProfile(9))
	for _, item := range []struct{ id, outbound string }{{"old", "synthetic"}, {"unrelated", "DIRECT"}} {
		c := &syntheticTracker{id: item.id, info: statistic.TrackerInfo{Metadata: &C.Metadata{NetWork: C.TCP}, Chain: C.Chain{item.outbound}, Start: time.Now()}}
		statistic.DefaultManager.Join(c)
		t.Cleanup(func() { _ = c.Close() })
	}
	if _, err := kernel.Control(id, []byte(`{"action":"select","group":"select","node":"synthetic"}`)); err != nil {
		t.Fatal(err)
	}
	if statistic.DefaultManager.Get("old") == nil {
		t.Fatal("selecting the same node closed connections")
	}
	if _, err := kernel.Control(id, []byte(`{"action":"select","group":"select","node":"REJECT"}`)); err != nil {
		t.Fatal(err)
	}
	if statistic.DefaultManager.Get("old") != nil || statistic.DefaultManager.Get("unrelated") == nil {
		t.Fatal("wrong connections were closed")
	}
}

func TestConnectionFiltersSearchBeforePaginationAndRetainClosedRows(t *testing.T) {
	id := startPacketCore(t, packetProfile(9))
	trackers := []*syntheticTracker{}
	for i := 0; i < 31; i++ {
		c := &syntheticTracker{id: fmt.Sprintf("synthetic-%02d", i), info: statistic.TrackerInfo{
			Metadata: &C.Metadata{Host: fmt.Sprintf("host-%02d.example.test", i), Process: "synthetic-process", NetWork: C.TCP},
			Start:    time.Now().Add(time.Duration(i) * time.Second),
		}}
		statistic.DefaultManager.Join(c)
		trackers = append(trackers, c)
	}
	t.Cleanup(func() {
		for _, c := range trackers {
			_ = c.Close()
		}
	})
	var snapshot struct {
		Total, Active, Closed int
		Connections           []struct {
			ID       string
			ClosedAt *time.Time
		}
	}
	read := func(request string) {
		t.Helper()
		data, err := kernel.Control(id, []byte(request))
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(data, &snapshot); err != nil {
			t.Fatal(err)
		}
	}
	read(`{"action":"snapshot","page":1,"scope":"all"}`)
	if snapshot.Total != 31 || len(snapshot.Connections) != 25 {
		t.Fatal("incorrect pagination")
	}
	read(`{"action":"snapshot","page":1,"scope":"all","query":"HOST-00"}`)
	if snapshot.Total != 1 || snapshot.Connections[0].ID != "synthetic-00" {
		t.Fatal("search only covered the visible page")
	}
	_ = trackers[0].Close()
	read(`{"action":"snapshot","page":1,"scope":"closed","query":"host-00"}`)
	if snapshot.Total != 1 || snapshot.Closed != 1 || snapshot.Active != 0 || snapshot.Connections[0].ClosedAt == nil {
		t.Fatal("closed row missing")
	}
	read(`{"action":"snapshot","page":1,"scope":"active","query":"synthetic-process"}`)
	if snapshot.Total != 30 || snapshot.Active != 30 {
		t.Fatal("active scope includes closed rows")
	}
	for _, request := range []string{`{"action":"snapshot","page":1,"scope":"unknown"}`, `{"action":"mode","mode":"invalid"}`, `{"action":"logs","page":1,"level":"trace"}`} {
		if _, err := kernel.Control(id, []byte(request)); err == nil {
			t.Fatal("invalid enum accepted")
		}
	}
	if _, err := kernel.Control(id, []byte(`{"action":"mode","mode":"direct"}`)); err != nil {
		t.Fatal(err)
	}
	data, err := kernel.Control(id, []byte(`{"action":"snapshot","page":1}`))
	if err != nil || !strings.Contains(string(data), `"mode":"direct"`) {
		t.Fatal("mode change not reflected by the core")
	}
}

func TestConnectionDetailsCloseOneAndAnnotateLogInbound(t *testing.T) {
	id := startPacketCore(t, packetProfile(9))
	detail := &syntheticTracker{id: "detail", info: statistic.TrackerInfo{
		Metadata: &C.Metadata{NetWork: C.TCP, Type: C.TUN, SrcIP: netip.MustParseAddr("198.18.0.1"), SrcPort: 61593,
			DstIP: netip.MustParseAddr("203.0.113.7"), DstPort: 443, Host: "detail.example.test", RemoteDst: "203.0.113.8",
			Process: "synthetic", ProcessPath: "/synthetic/bin/synthetic"},
		Chain: C.Chain{"synthetic", "select"}, Rule: "DomainSuffix", RulePayload: "example.test", Start: time.Now(),
	}}
	other := &syntheticTracker{id: "other", info: statistic.TrackerInfo{
		Metadata: &C.Metadata{NetWork: C.UDP, Type: C.HTTP, SrcIP: netip.MustParseAddr("fd00::1"), SrcPort: 5353, Host: "other.example.test", DstPort: 53},
		Chain:    C.Chain{"DIRECT"}, Start: time.Now(),
	}}
	for _, c := range []*syntheticTracker{detail, other} {
		statistic.DefaultManager.Join(c)
		t.Cleanup(func() { _ = c.Close() })
	}
	control := func(request string, value any) {
		t.Helper()
		data, err := kernel.Control(id, []byte(request))
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(data, value); err != nil {
			t.Fatal(err)
		}
	}
	var snapshot struct {
		Connections []struct {
			Source, Destination, IP, Port, RemoteDestination, RulePayload, ProcessPath, Inbound, Network string
		}
	}
	control(`{"action":"snapshot","page":1,"scope":"all","query":"detail.example.test"}`, &snapshot)
	if len(snapshot.Connections) != 1 {
		t.Fatal("detail connection missing")
	}
	if row := snapshot.Connections[0]; row.Source != "198.18.0.1:61593" || row.Destination != "detail.example.test:443" || row.IP != "203.0.113.7" ||
		row.Port != "443" || row.RemoteDestination != "203.0.113.8" || row.RulePayload != "example.test" ||
		row.ProcessPath != "/synthetic/bin/synthetic" || row.Inbound != "Tun" || row.Network != "tcp" {
		t.Fatalf("unexpected detail fields: %+v", row)
	}
	log.Infoln("[TCP] 198.18.0.1:61593(synthetic) --> detail.example.test:443 match DomainSuffix(example.test) using select[synthetic]")
	log.Infoln("[UDP] [fd00::1]:5353 --> other.example.test:53 using DIRECT")
	log.Infoln("[TCP] 198.18.0.9:1000 --> unknown.example.test:443 using DIRECT")
	inbound := func() map[string]string {
		t.Helper()
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			var logs struct {
				Entries []struct{ Message, Inbound string }
			}
			control(`{"action":"logs","page":1,"query":"example.test:"}`, &logs)
			if len(logs.Entries) >= 3 {
				result := map[string]string{}
				for _, entry := range logs.Entries {
					result[strings.Fields(entry.Message)[1]] = entry.Inbound
				}
				return result
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatal("connection logs were dropped")
		return nil
	}
	if tags := inbound(); tags["198.18.0.1:61593(synthetic)"] != "Tun" || tags["[fd00::1]:5353"] != "HTTP" || tags["198.18.0.9:1000"] != "" {
		t.Fatalf("unexpected log inbound tags: %+v", tags)
	}
	if _, err := kernel.Control(id, []byte(`{"action":"close"}`)); err == nil {
		t.Fatal("close accepted an empty id")
	}
	if _, err := kernel.Control(id, []byte(`{"action":"close","connectionID":"detail"}`)); err != nil {
		t.Fatal(err)
	}
	if statistic.DefaultManager.Get("detail") != nil || statistic.DefaultManager.Get("other") == nil {
		t.Fatal("close affected the wrong connections")
	}
	control(`{"action":"snapshot","page":1,"scope":"closed","query":"detail.example.test"}`, &snapshot)
	if len(snapshot.Connections) != 1 {
		t.Fatal("closed detail connection missing")
	}
	if tags := inbound(); tags["198.18.0.1:61593(synthetic)"] != "Tun" {
		t.Fatalf("closed connection lost its log inbound tag: %+v", tags)
	}
}

func TestLogLevelAndQueryFilterTheWholeBuffer(t *testing.T) {
	id := startPacketCore(t, packetProfile(9))
	log.Debugln("synthetic-debug-needle secret=synthetic-secret")
	for i := 0; i < 25; i++ {
		log.Infoln("synthetic-info-%d", i)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		data, err := kernel.Control(id, []byte(`{"action":"logs","page":1,"level":"debug","query":"DEBUG-NEEDLE"}`))
		if err != nil {
			t.Fatal(err)
		}
		var result struct {
			Total   int
			Entries []struct{ Level, Message string }
		}
		if json.Unmarshal(data, &result) != nil {
			t.Fatal("invalid logs")
		}
		if result.Total == 1 {
			if len(result.Entries) != 1 || result.Entries[0].Level != "debug" || strings.Contains(result.Entries[0].Message, "synthetic-secret") {
				t.Fatal("invalid filtered or unredacted log")
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("debug log was dropped or search only covered the visible page")
}
func TestBoundedLogsRedactCredentialsAndClearOnRestart(t *testing.T) {
	profile := packetProfile(9)
	proxy := profile["proxies"].([]any)[0].(map[string]any)
	proxy["password"] = "synthetic-password"
	id := startPacketCore(t, profile)
	for i := 0; i < 2030; i++ {
		log.Infoln("synthetic-password https://user:password@example.test/path?token=hidden secret=other Authorization: Bearer synthetic-bearer %d", i)
	}
	deadline := time.Now().Add(3 * time.Second)
	var result struct {
		Total   int
		Entries []struct {
			ID      int64
			Message string
		}
	}
	for time.Now().Before(deadline) {
		data, err := kernel.Control(id, []byte(`{"action":"logs","page":1}`))
		if err != nil {
			t.Fatal(err)
		}
		if json.Unmarshal(data, &result) != nil {
			t.Fatal("invalid logs")
		}
		if len(result.Entries) > 0 && result.Entries[0].ID >= 2030 {
			break
		}
		time.Sleep(time.Millisecond * 10)
	}
	if result.Total != 2000 || len(result.Entries) != 20 {
		t.Fatalf("unbounded or missing logs: total=%d entries=%d", result.Total, len(result.Entries))
	}
	for _, entry := range result.Entries {
		for _, secret := range []string{"synthetic-password", "user:password", "token=hidden", "other", "synthetic-bearer", "/path"} {
			if strings.Contains(entry.Message, secret) {
				t.Fatalf("credential exposed: %s", entry.Message)
			}
		}
	}
	kernel.Stop(id)
	next := startPacketCore(t, packetProfile(9))
	data, err := kernel.Control(next, []byte(`{"action":"logs","page":1}`))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "example.test/path") {
		t.Fatal("old logs crossed session boundary")
	}
}

func TestSettingsControlAndAccountScopedLogPersistence(t *testing.T) {
	profile := packetProfile(9)
	owner := strings.Repeat("a", 64)
	profile["rule-providers"] = map[string]any{"synthetic-rules": map[string]any{"type": "inline", "behavior": "domain", "payload": []string{"example.test"}}}
	data, _ := json.Marshal(profile)
	base := t.TempDir()
	directory := base + "/runtime"
	if err := os.Mkdir(directory, 0700); err != nil {
		t.Fatal(err)
	}
	logDirectory := base + "/Logs/" + owner
	if err := os.MkdirAll(logDirectory, 0700); err != nil {
		t.Fatal(err)
	}
	path := logDirectory + "/app-" + time.Now().Format("2006-01-02") + ".log"
	expired := logDirectory + "/app-" + time.Now().AddDate(0, 0, -30).Format("2006-01-02") + ".log"
	retained := logDirectory + "/app-" + time.Now().AddDate(0, 0, -29).Format("2006-01-02") + ".log"
	full := append(bytes.Repeat([]byte("a"), 2*1024*1024), bytes.Repeat([]byte("b"), 8*1024*1024)...)
	for file, data := range map[string][]byte{path: full, expired: {}, retained: {}} {
		if err := os.WriteFile(file, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	id, err := kernel.Start(data, directory, 0, "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { kernel.Stop(id) })
	if _, err := kernel.Control(id, []byte(fmt.Sprintf(`{"action":"logging","group":"%s","level":"warning"}`, owner))); err != nil {
		t.Fatal(err)
	}
	for _, command := range []string{`{"action":"version"}`, `{"action":"rules"}`, `{"action":"logging","level":"warning"}`, `{"action":"geodata","scope":"status"}`} {
		if _, err := kernel.Control(id, []byte(command)); err != nil {
			t.Fatal(err)
		}
	}
	for _, command := range []string{`{"action":"logging","level":"trace"}`, `{"action":"rules","scope":"content","group":"../config.json","page":1}`} {
		if _, err := kernel.Control(id, []byte(command)); err == nil {
			t.Fatal("unsafe control accepted")
		}
	}
	log.Infoln("synthetic-info-omitted")
	log.Warnln("synthetic-warning token=private-value")
	var saved []byte
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		saved, _ = os.ReadFile(path)
		if strings.Contains(string(saved), "synthetic-warning") {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if !strings.Contains(string(saved), "synthetic-warning") || strings.Contains(string(saved), "private-value") || strings.Contains(string(saved), "synthetic-info-omitted") {
		t.Fatal("invalid saved log")
	}
	if len(saved) < 8*1024*1024 || len(saved) >= 10*1024*1024 || bytes.Count(saved[:8*1024*1024], []byte("b")) != 8*1024*1024 {
		t.Fatal("log rotation did not retain recent data")
	}
	if _, err := os.Stat(expired); !os.IsNotExist(err) {
		t.Fatal("expired log retained")
	}
	if _, err := os.Stat(retained); err != nil {
		t.Fatal("recent log removed")
	}
	if _, err := kernel.Control(id, []byte(`{"action":"logging","level":"silent"}`)); err != nil {
		t.Fatal(err)
	}
	log.Errorln("synthetic-silent-omitted")
	kernel.Stop(id)
	final, _ := os.ReadFile(path)
	if string(final) != string(saved) {
		t.Fatal("silent wrote logs")
	}
}

func TestRuleReaderOnlyReadsDeclaredFilesInsideRuntime(t *testing.T) {
	if isolated(t) {
		return
	}
	base := t.TempDir()
	directory := base + "/runtime"
	if err := os.Mkdir(directory, 0700); err != nil {
		t.Fatal(err)
	}
	path := directory + "/rules.yaml"
	content := []byte("payload:\n  - example.test\n")
	if err := os.WriteFile(path, content, 0600); err != nil {
		t.Fatal(err)
	}
	profile := packetProfile(9)
	profile["rule-providers"] = map[string]any{"declared": map[string]any{"type": "file", "behavior": "domain", "path": "rules.yaml"}}
	data, _ := json.Marshal(profile)
	id, err := kernel.Start(data, directory, 0, "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { kernel.Stop(id) })
	result, err := kernel.Control(id, []byte(`{"action":"rules","scope":"content","group":"declared","page":1}`))
	if err != nil {
		t.Fatal(err)
	}
	var chunk struct {
		Data    []byte
		Done    bool
		Version string
	}
	if json.Unmarshal(result, &chunk) != nil || string(chunk.Data) != string(content) || !chunk.Done {
		t.Fatalf("incorrect content: %s", result)
	}
	if err := os.WriteFile(path, []byte("payload:\n  - changed.example.test\n"), 0600); err != nil {
		t.Fatal(err)
	}
	command, _ := json.Marshal(map[string]any{"action": "rules", "scope": "content", "group": "declared", "page": 2, "query": chunk.Version})
	if _, err := kernel.Control(id, command); err == nil {
		t.Fatal("mixed revisions accepted")
	}
	if err := os.WriteFile(base+"/private", []byte("private"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(base+"/private", path); err != nil {
		t.Fatal(err)
	}
	if _, err := kernel.Control(id, []byte(`{"action":"rules","scope":"content","group":"declared","page":1}`)); err == nil {
		t.Fatal("symlink escaped runtime")
	}
}

func TestLargeSnapshotFitsControlCapacity(t *testing.T) {
	profile := packetProfile(9)
	var proxies []any
	members := []string{"REJECT"}
	for i := 0; i < 3000; i++ {
		name := fmt.Sprintf("synthetic-node-%04d", i)
		proxies = append(proxies, map[string]any{"name": name, "type": "socks5", "server": "127.0.0.1", "port": 9})
		members = append(members, name)
	}
	profile["proxies"] = proxies
	profile["proxy-groups"] = []any{map[string]any{"name": "select", "type": "select", "proxies": members}}
	id := startPacketCore(t, profile)
	data, err := kernel.Control(id, []byte(`{"action":"snapshot","page":1}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(data) <= 65536 || len(data) > kernel.MaximumControlBytes {
		t.Fatalf("snapshot size %d", len(data))
	}
	if _, err := kernel.Control(id, []byte(`{"action":"select","group":"select","node":"synthetic-node-2999"}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := kernel.Control(id, []byte(`{"action":"select","group":"select","node":"missing"}`)); err == nil {
		t.Fatal("selected a node outside the group")
	}
}

func TestEmptyNodeProviderRefusesButEmptyRuleSetStarts(t *testing.T) {
	directory := t.TempDir()
	if err := os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "rules.yaml"), []byte("payload: []\n"), 0600); err != nil {
		t.Fatal(err)
	}
	profile := packetProfile(9)
	profile["rule-providers"] = map[string]any{"empty": map[string]any{"type": "file", "behavior": "domain", "path": "rules.yaml"}}
	profile["rules"] = []string{"RULE-SET,empty,REJECT", "MATCH,select"}
	data, _ := json.Marshal(profile)
	id, err := kernel.Start(data, directory, 0, "", "", "")
	if err != nil {
		t.Fatalf("empty rule set blocked start: %v", err)
	}
	kernel.Stop(id)
	if err := os.WriteFile(filepath.Join(directory, "nodes.yaml"), []byte("proxies: []\n"), 0600); err != nil {
		t.Fatal(err)
	}
	profile = packetProfile(9)
	profile["proxy-providers"] = map[string]any{"ecy-panel-nodes": map[string]any{"type": "file", "path": "nodes.yaml"}}
	data, _ = json.Marshal(profile)
	if _, err := kernel.Start(data, directory, 0, "", "", ""); err != kernel.ErrNoNodes {
		t.Fatalf("empty node provider: %v", err)
	}
	// 已停止内核的出站在终结器里写日志，与下一个用例 ApplyConfig 改日志级别竞争（mihomo log 包未加锁）
	runtime.GC()
	time.Sleep(200 * time.Millisecond)
}

func TestUpdateNodesReloadsPanelNodesWithoutRestart(t *testing.T) {
	directory := t.TempDir()
	if err := os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	probe := "ecy-panel-" + strings.Repeat("ab", 32)
	probed := []any{map[string]any{"name": "ecy-panel-empty", "type": "reject"}}
	build := func(names ...string) []byte {
		nodes := []any{}
		for _, name := range names {
			nodes = append(nodes, map[string]any{"name": name, "type": "socks5", "server": "127.0.0.1", "port": 9, "password": "secret-" + name})
		}
		profile := packetProfile(9)
		profile["proxies"] = []any{}
		profile["proxy-providers"] = map[string]any{
			"ecy-panel-nodes": map[string]any{"type": "file", "path": "ecy-panel-nodes.json", "payload": nodes},
			probe:             map[string]any{"type": "file", "path": probe + ".json", "payload": probed},
		}
		profile["proxy-groups"] = []any{map[string]any{"name": "select", "type": "select", "proxies": []string{"REJECT"}, "use": []string{"ecy-panel-nodes"}}}
		data, err := json.Marshal(profile)
		if err != nil {
			t.Fatal(err)
		}
		return data
	}
	id, err := kernel.Start(build("node-a", "node-b"), directory, 0, "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { kernel.Stop(id) })
	members := func() string {
		value, err := kernel.Control(id, []byte(`{"action":"snapshot","page":1}`))
		if err != nil {
			t.Fatal(err)
		}
		var snapshot struct {
			Groups []struct {
				ID      string
				Members []string
			}
		}
		if err := json.Unmarshal(value, &snapshot); err != nil {
			t.Fatal(err)
		}
		for _, group := range snapshot.Groups {
			if group.ID == "select" {
				return strings.Join(group.Members, ",")
			}
		}
		return ""
	}
	if got := members(); !strings.Contains(got, "node-a") || !strings.Contains(got, "node-b") {
		t.Fatalf("initial members: %s", got)
	}
	if err := kernel.UpdateNodes(id+1, build("node-c")); err != kernel.ErrStopped {
		t.Fatalf("stale session: %v", err)
	}
	if err := kernel.UpdateNodes(id, build()); err != kernel.ErrConfiguration {
		t.Fatalf("empty payload: %v", err)
	}
	if err := kernel.UpdateNodes(id, build("node-a", "node-c")); err != nil {
		t.Fatal(err)
	}
	if got := members(); !strings.Contains(got, "node-a") || !strings.Contains(got, "node-c") || strings.Contains(got, "node-b") {
		t.Fatalf("updated members: %s", got)
	}
	// 测试未装入的节点只改探测节点文件：内容没变的节点文件不重写，内核也就不会换掉其中的出站
	if _, err := os.Stat(filepath.Join(directory, probe+".json")); !os.IsNotExist(err) {
		t.Fatalf("unchanged probe file was written: %v", err)
	}
	before, err := os.Stat(filepath.Join(directory, "ecy-panel-nodes.json"))
	if err != nil {
		t.Fatal(err)
	}
	probed = []any{map[string]any{"name": "node-x", "type": "socks5", "server": "127.0.0.1", "port": 9}}
	if err := kernel.UpdateNodes(id, build("node-a", "node-c")); err != nil {
		t.Fatal(err)
	}
	if after, err := os.Stat(filepath.Join(directory, "ecy-panel-nodes.json")); err != nil || !os.SameFile(before, after) {
		t.Fatalf("unchanged node file was rewritten: %v", err)
	}
	if _, err := kernel.Control(id, []byte(`{"action":"probe","node":"node-x","scope":"delay"}`)); err != nil {
		t.Fatalf("probe node was not loaded: %v", err)
	}
	if got := members(); strings.Contains(got, "node-x") {
		t.Fatalf("probe node joined a group: %s", got)
	}
	if _, err := kernel.Start(build("node-a"), directory, 0, "", "", ""); err != kernel.ErrBusy {
		t.Fatalf("kernel was restarted: %v", err)
	}
}
func TestDialFailureLogNamesTheNode(t *testing.T) {
	id := startPacketCore(t, packetProfile(9))
	log.Warnln("[TCP] dial select (match Match/) 198.18.0.1:1 --> addr-needle.example.test:443 error: 127.0.0.1:9 connect error: EOF")
	log.Warnln("[TCP] dial select (match Match/) 198.18.0.1:2 --> live-needle.example.test:443 error: context deadline exceeded")
	log.Warnln("[TCP] dial select (match Match/) 198.18.0.1:3 --> other-needle.example.test:443 error: 192.0.2.9:1 connect error: EOF")
	log.Warnln("[TCP] dial DIRECT (match GeoIP/cn) 198.18.0.1:4 --> direct-needle.example.test:443 error: dial tcp 192.0.2.8:443: i/o timeout")
	want := map[string]string{
		"addr-needle":   "[TCP] dial select → synthetic (match Match/) 198.18.0.1:1 --> addr-needle.example.test:443 error: 127.0.0.1:9 connect error: EOF",
		"live-needle":   "[TCP] dial select → synthetic (match Match/) 198.18.0.1:2 --> live-needle.example.test:443 error: context deadline exceeded",
		"other-needle":  "[TCP] dial select (match Match/) 198.18.0.1:3 --> other-needle.example.test:443 error: 192.0.2.9:1 connect error: EOF",
		"direct-needle": "[TCP] dial DIRECT (match GeoIP/cn) 198.18.0.1:4 --> direct-needle.example.test:443 error: dial tcp 192.0.2.8:443: i/o timeout",
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		data, err := kernel.Control(id, []byte(`{"action":"logs","page":1,"level":"warning","query":"-needle.example.test"}`))
		if err != nil {
			t.Fatal(err)
		}
		var result struct{ Entries []struct{ Message string } }
		if json.Unmarshal(data, &result) != nil {
			t.Fatal("invalid logs")
		}
		if len(result.Entries) == len(want) {
			for _, entry := range result.Entries {
				key := strings.SplitN(strings.SplitN(entry.Message, "--> ", 2)[1], ".", 2)[0]
				if entry.Message != want[key] {
					t.Fatalf("%s: got %q", key, entry.Message)
				}
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("dial failure logs were dropped")
}
