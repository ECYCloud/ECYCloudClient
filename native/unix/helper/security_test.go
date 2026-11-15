//go:build darwin || linux

package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestPanelProviderFilesRejectUnsafePaths(t *testing.T) {
	for _, path := range []string{"../outside", "config.json", "ecy-panel-nodes.json:stream", `C:\Windows\win.ini`, "ecy-panel-nodes.json"} {
		input := `{"proxy-providers":{"ecy-panel-nodes":{"type":"file","path":` + strconv.Quote(path) + `,"payload":[{"name":"node-1","type":"direct"}]}}}`
		files, err := panelProviderFiles(input)
		if path == "ecy-panel-nodes.json" {
			if err != nil || !strings.Contains(string(files[path]), `"proxies":[`) {
				t.Fatalf("合法节点文件不能写入: %v", err)
			}
		} else if err == nil {
			t.Fatalf("越界或客户端保留路径必须拒绝: %s", path)
		}
	}
	for _, raw := range []string{
		`{"ecy-panel-nodes":{"type":"inline","path":"ecy-panel-nodes.json","payload":[{}]}}`,
		`{"ecy-panel-nodes":{"type":"file","path":"ecy-panel-nodes.json","payload":[]}}`,
		`{"ecy-panel-../escape":{"type":"file","path":"ecy-panel-../escape.json","payload":[{}]}}`,
	} {
		if _, err := panelProviderFiles(`{"proxy-providers":` + raw + `}`); err == nil {
			t.Fatal("损坏节点文件配置必须拒绝")
		}
	}
}

func TestSanitizeKernelConfigStripsPrivilegedKeys(t *testing.T) {
	input := `{"external-ui":"/tmp/evil","external-ui-url":"http://evil/ui.zip",` +
		`"ss-config":"ss://inbound","vmess-config":"vmess://inbound","tuic-server":{"enable":true},` +
		`"iptables":{"enable":true},` +
		`"ntp":{"enable":true,"server":"time.test","write-to-system":true},` +
		`"mixed-port":10203,"secret":"keep-me"}`
	out, err := sanitizeKernelConfig(input)
	if err != nil {
		t.Fatal(err)
	}
	var top map[string]any
	if err := json.Unmarshal([]byte(out), &top); err != nil {
		t.Fatal(err)
	}
	if top["external-ui"] != "" || top["external-ui-url"] != "" {
		t.Fatalf("external-ui / external-ui-url 必须被清空: %s", out)
	}
	if top["ss-config"] != "" || top["vmess-config"] != "" || top["tuic-server"].(map[string]any)["enable"] != false {
		t.Fatalf("不能启动独立入站服务: %s", out)
	}
	if top["iptables"].(map[string]any)["enable"] != false {
		t.Fatalf("内核不能自行修改防火墙: %s", out)
	}
	ntp, ok := top["ntp"].(map[string]any)
	if !ok || ntp["write-to-system"] != false {
		t.Fatalf("ntp.write-to-system 必须关闭: %s", out)
	}
	if ntp["server"] != "time.test" || ntp["enable"] != true {
		t.Fatalf("ntp 其它字段必须保留: %s", out)
	}
	if top["mixed-port"] != float64(10203) || top["secret"] != "keep-me" {
		t.Fatalf("其它配置键必须原样保留: %s", out)
	}
	if !strings.Contains(out, "\n  \"mixed-port\": 10203") || !strings.Contains(out, "\n    \"write-to-system\": false") {
		t.Fatalf("落盘配置必须按两空格缩进: %s", out)
	}
	if ss, ipt := strings.Index(out, "\n  \"ss-config\""), strings.Index(out, "\n  \"iptables\""); ss < 0 || ipt < 0 || ss > ipt {
		t.Fatalf("必须保留原有键顺序: %s", out)
	}
	out2, err := sanitizeKernelConfig(`{"mixed-port":10203}`)
	if err != nil {
		t.Fatal(err)
	}
	var top2 map[string]any
	if err := json.Unmarshal([]byte(out2), &top2); err != nil {
		t.Fatal(err)
	}
	if top2["external-ui"] != "" || top2["external-ui-url"] != "" {
		t.Fatalf("缺省配置也必须显式关闭 external-ui: %s", out2)
	}
	for _, invalid := range []string{"not-json", "null", "[]"} {
		if _, err := sanitizeKernelConfig(invalid); err == nil {
			t.Fatalf("非对象配置必须被拒绝: %s", invalid)
		}
	}
	if _, err := sanitizeKernelConfig(`{"ntp":null}`); err != nil {
		t.Fatalf("空 NTP 不得引发异常: %v", err)
	}
}

func TestWriteKernelFileRejectsLinks(t *testing.T) {
	previousUID, previousGID := kernelUID, kernelGID
	kernelUID, kernelGID = os.Getuid(), os.Getgid()
	t.Cleanup(func() { kernelUID, kernelGID = previousUID, previousGID })
	base := t.TempDir()
	protected := filepath.Join(base, "protected")
	if err := os.WriteFile(protected, []byte("unchanged"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, kind := range []string{"symlink", "hardlink"} {
		t.Run(kind, func(t *testing.T) {
			target := filepath.Join(base, kind)
			var err error
			if kind == "symlink" {
				err = os.Symlink(protected, target)
			} else {
				err = os.Link(protected, target)
			}
			if err != nil {
				t.Fatal(err)
			}
			if err := writeKernelFile(target, strings.NewReader("overwritten")); err == nil {
				t.Fatal("不能跟随链接写入特权文件")
			}
			data, err := os.ReadFile(protected)
			if err != nil || string(data) != "unchanged" {
				t.Fatalf("原文件被修改: %q, %v", data, err)
			}
		})
	}
	file := filepath.Join(base, "config.json")
	if err := writeKernelFile(file, strings.NewReader("long original")); err != nil {
		t.Fatal(err)
	}
	if err := writeKernelFile(file, strings.NewReader("new")); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(file)
	if err != nil || string(data) != "new" {
		t.Fatalf("正常配置写入失败: %q, %v", data, err)
	}
}

func TestOwnedDirRejectsSymlink(t *testing.T) {
	base := t.TempDir()
	target := filepath.Join(base, "real")
	if err := os.Mkdir(target, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(base, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if err := ensureOwnedDir(link, os.Getuid(), os.Getgid(), 0o700); err == nil {
		t.Fatal("不能收归软链接目录")
	}
	info, err := os.Stat(target)
	if err != nil || info.Mode().Perm() != 0o755 {
		t.Fatalf("链接目标权限被修改: %v", err)
	}
	if err := ensureOwnedDir(filepath.Join(base, "missing-user"), -1, -1, 0o700); err == nil {
		t.Fatal("用户缺失时必须失败")
	}
}

func TestUntrustedCallerDenied(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if err := verifyGUICaller(exe); err == nil {
		t.Fatal("非官方程序不能调用 helper")
	}
}

func TestOwnedDirRejectsUntrustedOwner(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("需要 root 验证跨账户目录属主")
	}
	dir := filepath.Join(t.TempDir(), "untrusted")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chown(dir, 65534, 65534); err != nil {
		t.Fatal(err)
	}
	if err := ensureOwnedDir(dir, 0, 0, 0o700); err == nil {
		t.Fatal("不能把非特权用户预建的目录收为 root 后继续使用")
	}
	info, err := os.Stat(dir)
	if err != nil || info.Mode().Perm() != 0o755 {
		t.Fatalf("拒绝后不能修改原目录权限: %v", err)
	}
}

func TestPeerIdentityUsesSocketCredentials(t *testing.T) {
	const marker = "ECYCLOUD_TEST_PEER_SOCKET"
	if socket := os.Getenv(marker); socket != "" {
		conn, err := net.Dial("unix", socket)
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		if _, err := conn.Write([]byte(`{"pid":1,"uid":0}`)); err != nil {
			t.Fatal(err)
		}
		var ack [1]byte
		if _, err := conn.Read(ack[:]); err != nil {
			t.Fatal(err)
		}
		return
	}
	if os.Geteuid() != 0 {
		t.Skip("需要 root 创建不同 UID 的测试进程")
	}
	dir, err := os.MkdirTemp("", "peer-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(dir, "peer.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socket, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := os.Chmod(socket, 0o666); err != nil {
		t.Fatal(err)
	}
	program, err := os.ReadFile(os.Args[0])
	if err != nil {
		t.Fatal(err)
	}
	childPath := filepath.Join(dir, "peer-test")
	if err := os.WriteFile(childPath, program, 0o755); err != nil {
		t.Fatal(err)
	}
	child := exec.Command(childPath, "-test.run=^TestPeerIdentityUsesSocketCredentials$")
	child.Env = append(os.Environ(), marker+"="+socket)
	child.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: 65534, Gid: 65534}}
	child.Stderr = os.Stderr
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { child.Process.Kill(); child.Wait() })
	listener.SetDeadline(time.Now().Add(5 * time.Second))
	conn, err := listener.AcceptUnix()
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	caller, err := peerIdentity(conn, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	defer caller.close()
	if caller.pid != child.Process.Pid || caller.user != "65534" {
		t.Fatalf("必须采用操作系统记录的 UID/PID: %d, %s", caller.pid, caller.user)
	}
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	var payload [64]byte
	if _, err := conn.Read(payload[:]); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Write([]byte{1}); err != nil {
		t.Fatal(err)
	}
	if err := child.Wait(); err != nil {
		t.Fatal(err)
	}
}

func TestSessionRejectsOtherSystemAccount(t *testing.T) {
	s := newServer()
	s.owner, s.watched = "account-a", os.Getpid()
	s.kernel.running = true
	s.kernel.logs.append("account-a-private")
	for _, command := range []string{
		"ping", "tun.ensure", "kernel.start", "kernel.stop", "kernel.clear", "kernel.status",
		"kernel.check", "kernel.write", "kernel.read", "kernel.upgrade",
		"kernel.upgrade.progress", "kernel.upgrade.commit", "kernel.upgrade.rollback",
		"proxy.set", "proxy.restore", "proxy.state",
	} {
		t.Run(command, func(t *testing.T) {
			value, err := s.dispatch(request{
				Command: command, PID: s.watched, Path: "config.json",
				Config: "{}", Port: 7890, Version: "1.19.29",
			}, os.Getpid(), "account-b")
			if err == nil || value != nil || !strings.Contains(err.Error(), "另一系统账号") {
				t.Fatalf("其它账号不能执行 %s: %v, %v", command, value, err)
			}
			if s.owner != "account-a" || !s.kernel.running {
				t.Fatal("拒绝请求不能改变旧会话")
			}
		})
	}
	value, err := s.dispatch(request{Command: "kernel.status"}, os.Getpid(), "account-a")
	if err != nil || !value.(kernelStatus).Running {
		t.Fatalf("会话所属账号仍应可用: %v, %v", value, err)
	}
}

func TestSessionFailsClosedWithoutIdentityOrDuringShutdown(t *testing.T) {
	s := newServer()
	for _, caller := range []struct {
		pid  int
		user string
	}{{0, "a"}, {os.Getpid(), ""}} {
		if err := s.lockSession(caller.pid, caller.user); err == nil {
			s.mu.RUnlock()
			t.Fatal("身份不完整时不能占用会话")
		}
	}
	s.closing = true
	if err := s.lockSession(os.Getpid(), "a"); err == nil {
		s.mu.RUnlock()
		t.Fatal("服务停止时不能接收新会话")
	}
}

func TestGarbageCollectionKeepsRecentAccountsOnly(t *testing.T) {
	base := filepath.Join(t.TempDir(), "run")
	current, recent, stale, unmarked := strings.Repeat("a", 64), strings.Repeat("b", 64), strings.Repeat("c", 64), strings.Repeat("d", 64)
	for _, dir := range []string{current, recent, stale, unmarked} {
		if err := os.MkdirAll(filepath.Join(base, dir, "providers"), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(base, dir, "cache.db"), []byte(dir), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	touchLastUsed(filepath.Join(base, recent))
	touchLastUsed(filepath.Join(base, stale))
	old := time.Now().Add(-sessionRetention - time.Hour)
	if err := os.Chtimes(filepath.Join(base, stale, lastUsedName), old, old); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"config.json", "cache.db", "proxy-snapshot.json"} {
		if err := os.WriteFile(filepath.Join(base, name), []byte("legacy"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(filepath.Dir(base), ".cache-owner"), []byte("legacy"), 0o600); err != nil {
		t.Fatal(err)
	}
	outside := t.TempDir()
	protected := filepath.Join(outside, "protected")
	if err := os.WriteFile(protected, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	linked := os.Symlink(outside, filepath.Join(base, strings.Repeat("e", 64))) == nil
	activeSession = current
	defer func() { activeSession = "" }()
	collectGarbage(base)
	for _, name := range []string{stale, unmarked, "config.json", "cache.db", strings.Repeat("e", 64)} {
		if _, err := os.Lstat(filepath.Join(base, name)); !os.IsNotExist(err) {
			t.Fatalf("过期或无归属的运行数据仍在: %s %v", name, err)
		}
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(base), ".cache-owner")); !os.IsNotExist(err) {
		t.Fatalf("旧版缓存归属文件仍在: %v", err)
	}
	for _, name := range []string{"proxy-snapshot.json", current + "/cache.db", recent + "/cache.db"} {
		if _, err := os.Stat(filepath.Join(base, name)); err != nil {
			t.Fatalf("当前账号、30 天内用过的账号或代理快照被删: %s %v", name, err)
		}
	}
	if !linked {
		t.Log("当前环境无法创建目录链接，链接子项未验证")
	} else if content, err := os.ReadFile(protected); err != nil || string(content) != "keep" {
		t.Fatalf("回收不能跟随目录链接: %q, %v", content, err)
	}
}

func TestSessionExitDropsRuntimeSecretsButKeepsCache(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"config.json", "config.check.json", "ecy-panel-nodes.json", "cache.db", "rules.mrs"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("test"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	dropRuntimeSecrets(dir)
	for _, name := range []string{"config.json", "config.check.json", "ecy-panel-nodes.json"} {
		if _, err := os.Stat(filepath.Join(dir, name)); !os.IsNotExist(err) {
			t.Fatalf("带节点凭据的运行文件残留: %s", name)
		}
	}
	for _, name := range []string{"cache.db", "rules.mrs"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Fatalf("同账号的缓存丢失: %s %v", name, err)
		}
	}
}

func TestLateSignOutOfOldAccountKeepsNewAccountBound(t *testing.T) {
	s := newServer()
	activeSession = strings.Repeat("b", 64)
	defer func() { activeSession = "" }()
	s.kernel.logs.append("account-b-log")
	if _, err := s.dispatch(request{Command: "kernel.clear", CacheKey: strings.Repeat("a", 64)}, os.Getpid(), "account"); err != nil {
		t.Fatal(err)
	}
	if activeSession != strings.Repeat("b", 64) || len(s.kernel.status(0).LogLines) != 1 {
		t.Fatal("旧账号晚到的退出不能停掉或解绑新账号")
	}
	if _, err := s.dispatch(request{Command: "kernel.clear", CacheKey: "../x"}, os.Getpid(), "account"); err == nil {
		t.Fatal("非法账号键必须拒绝")
	}
}

func TestKernelCommandsRequireBoundSession(t *testing.T) {
	s := newServer()
	for _, command := range []string{"kernel.start", "kernel.check", "kernel.write", "kernel.reload", "kernel.read"} {
		_, err := s.dispatch(request{Command: command, Config: "{}", Path: "config.json"}, os.Getpid(), "account-a")
		if err == nil || !strings.Contains(err.Error(), "尚未绑定登录会话") {
			t.Fatalf("%s 未绑定会话时必须拒绝: %v", command, err)
		}
	}
	for _, key := range []string{"../escape", strings.Repeat("g", 64), ""} {
		if _, err := s.dispatch(request{Command: "kernel.bind", CacheKey: key}, os.Getpid(), "account-a"); err == nil {
			t.Fatalf("会话键被当成路径: %q", key)
		}
	}
	if activeSession != "" {
		t.Fatal("非法会话键不能改变当前绑定")
	}
}

func TestSanitizeKernelConfigDisablesSecretlessControllers(t *testing.T) {
	keys := []string{"external-controller-unix", "external-controller-pipe", "external-controller-tls", "external-doh-server"}
	for _, input := range []string{
		`{"external-controller-unix":"/etc/passwd","external-controller-pipe":"\\\\.\\pipe\\evil",` +
			`"external-controller-tls":"0.0.0.0:9443","external-doh-server":"/dns-query","mixed-port":10203}`,
		`{"mixed-port":10203}`,
	} {
		out, err := sanitizeKernelConfig(input)
		if err != nil {
			t.Fatal(err)
		}
		var top map[string]any
		if err := json.Unmarshal([]byte(out), &top); err != nil {
			t.Fatal(err)
		}
		for _, key := range keys {
			if value, ok := top[key]; !ok || value != "" {
				t.Fatalf("%s 必须显式清空: %s", key, out)
			}
		}
		if top["mixed-port"] != float64(10203) {
			t.Fatalf("其余配置必须保留: %s", out)
		}
	}
}

func TestKernelUpgradeRejectsDowngrade(t *testing.T) {
	match := installedVersionPattern.FindStringSubmatch("Mihomo Meta v1.19.33 darwin arm64 with go1.25.1 Mon Oct 6 2026")
	if match == nil || match[1] != "1.19.33" {
		t.Fatalf("应从 mihomo -v 取出版本号: %v", match)
	}
	for _, c := range []struct {
		next, current string
		want          int
	}{
		{"1.19.34", "1.19.33", 1}, {"1.19.33", "1.19.33", 0}, {"1.19.9", "1.19.33", -1},
		{"1.18.10", "1.19.0", -1}, {"2.0", "1.19.33", 1}, {"1.19.33.1", "1.19.33", 1},
	} {
		if got := compareKernelVersion(c.next, c.current); got != c.want {
			t.Fatalf("compareKernelVersion(%s, %s) = %d，期望 %d", c.next, c.current, got, c.want)
		}
	}
}

func TestSanitizeKernelConfigClosesExtraInbounds(t *testing.T) {
	out, err := sanitizeKernelConfig(`{"port":7890,"socks-port":7891,"redir-port":7892,"tproxy-port":7893,` +
		`"tunnels":[{"network":["tcp"],"address":"0.0.0.0:2222","target":"10.0.0.1:22"}],` +
		`"listeners":[{"name":"ecy-speed","type":"mixed","listen":"127.0.0.1","port":10204,"users":[{"username":"u","password":"p"}]}],` +
		`"external-controller":"127.0.0.1:9090","mixed-port":10203}`)
	if err != nil {
		t.Fatal(err)
	}
	var top map[string]any
	if err := json.Unmarshal([]byte(out), &top); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"port", "socks-port", "redir-port", "tproxy-port"} {
		if top[key] != float64(0) {
			t.Fatalf("%s 必须关闭: %s", key, out)
		}
	}
	if tunnels, ok := top["tunnels"].([]any); !ok || len(tunnels) != 0 {
		t.Fatalf("端口转发必须清空: %s", out)
	}
	if listeners, ok := top["listeners"].([]any); !ok || len(listeners) != 1 || top["external-controller"] != "127.0.0.1:9090" || top["mixed-port"] != float64(10203) {
		t.Fatalf("GUI 的回环测速入站、控制面与混合端口必须保留: %s", out)
	}
	defaults, err := sanitizeKernelConfig(`{"mixed-port":10203}`)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(defaults, `"socks-port": 0`) || !strings.Contains(defaults, `"tunnels": []`) {
		t.Fatalf("缺省配置也必须显式关闭: %s", defaults)
	}
	for _, rejected := range []string{
		`{"external-controller":"0.0.0.0:9090"}`,
		`{"external-controller":":9090"}`,
		`{"external-controller":"192.168.1.2:9090"}`,
		`{"external-controller":9090}`,
		`{"listeners":[{"type":"mixed","listen":"0.0.0.0","port":1080}]}`,
		`{"listeners":[{"type":"mixed","port":1080}]}`,
		`{"listeners":[{"type":"tun","listen":"127.0.0.1"}]}`,
		`{"listeners":[{"type":"tunnel","listen":"127.0.0.1","port":2222,"target":"10.0.0.1:22"}]}`,
		`{"listeners":{"type":"mixed"}}`,
	} {
		if _, err := sanitizeKernelConfig(rejected); err == nil {
			t.Fatalf("非回环控制面或额外入站必须拒绝: %s", rejected)
		}
	}
}

// 热载改由特权侧通知内核按刚净化落盘的文件重载：请求只带默认路径与密钥，不带配置原文；
// 控制面地址按原键名精确读取，且只认回环，大小写变体不能把带密钥的请求引到别处
func TestNotifyKernelReloadSendsOnlyPathToLoopbackController(t *testing.T) {
	var method, query, auth, body string
	status := http.StatusNoContent
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		method, query, auth, body = r.Method+" "+r.URL.Path, r.URL.RawQuery, r.Header.Get("Authorization"), string(data)
		w.WriteHeader(status)
		_, _ = w.Write([]byte(`{"message":"synthetic failure"}`))
	}))
	defer server.Close()
	controller := strings.TrimPrefix(server.URL, "http://")
	config := `{"EXTERNAL-CONTROLLER":"192.0.2.1:9","external-controller":"` + controller + `","secret":"reload-secret","listeners":[]}`
	if err := notifyKernelReload(config); err != nil {
		t.Fatal(err)
	}
	if method != "PUT /configs" || query != "force=true" || auth != "Bearer reload-secret" || body != `{"path":""}` {
		t.Fatalf("热载请求不对: %s %s %s %s", method, query, auth, body)
	}
	status = http.StatusBadRequest
	if err := notifyKernelReload(config); err == nil || !strings.Contains(err.Error(), "HTTP 400") {
		t.Fatalf("内核拒绝重载必须报错: %v", err)
	}
	method = ""
	for _, rejected := range []string{
		`{"secret":"reload-secret"}`,
		`{"external-controller":"0.0.0.0:9090","secret":"reload-secret"}`,
		`{"external-controller":"192.0.2.1:9090","secret":"reload-secret"}`,
		`{"external-controller":":9090","secret":"reload-secret"}`,
		`{"external-controller":"` + controller + `","secret":7}`,
	} {
		if err := notifyKernelReload(rejected); err == nil || method != "" {
			t.Fatalf("非回环或缺失的控制面不得收到带密钥的请求: %s", rejected)
		}
	}
}

// 普通 provider 的保存路径与 GUI 同一份保留名单：字段名不分大小写，拒绝 ~ 短名、越界与客户端文件，合法路径照常放行
func TestWithoutPanelPayloadsKeepsOrderAndProviderFiles(t *testing.T) {
	config := `{"mode":"rule","proxy-providers":{"ecy-panel-nodes":{"type":"file","path":"ecy-panel-nodes.json","PayLoad":[{"name":"node-1","type":"direct"}]},"ecy-panel-` + strings.Repeat("a", 64) + `":{"payload":[{"name":"node-1","type":"direct"}],"type":"file","path":"ecy-panel-` + strings.Repeat("a", 64) + `.json"},"custom":{"type":"inline","payload":[{"name":"c","type":"direct"}]}},"rules":["MATCH,DIRECT"]}`
	files, err := panelProviderFiles(config)
	if err != nil || len(files) != 2 {
		t.Fatalf("节点文件仍须按 payload 生成: %v", err)
	}
	stripped, err := withoutPanelPayloads(config)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(strings.ToLower(stripped), `"payload":[{"name":"node-1"`) || strings.Contains(stripped, "PayLoad") {
		t.Fatalf("面板节点 provider 的 payload 必须去掉: %s", stripped)
	}
	if !strings.Contains(stripped, `"name": "c"`) {
		t.Fatalf("非面板 provider 必须原样保留: %s", stripped)
	}
	if strings.Index(stripped, `"mode"`) > strings.Index(stripped, `"proxy-providers"`) || strings.Index(stripped, `"proxy-providers"`) > strings.Index(stripped, `"rules"`) {
		t.Fatalf("顶层键顺序必须保持: %s", stripped)
	}
	var top struct {
		Providers map[string]map[string]any `json:"proxy-providers"`
	}
	if err := json.Unmarshal([]byte(stripped), &top); err != nil {
		t.Fatal(err)
	}
	if top.Providers["ecy-panel-nodes"]["path"] != "ecy-panel-nodes.json" || top.Providers["ecy-panel-nodes"]["type"] != "file" {
		t.Fatalf("节点 provider 的 type 与 path 必须保留: %s", stripped)
	}
}

func TestSanitizeKernelConfigRejectsReservedProviderPaths(t *testing.T) {
	for _, path := range []string{
		"config.json", "./CONFIG.JSON", "cache.db", "Cache.DB.bak", "config.check.json", "proxy-snapshot.json", "geoip.metadb",
		"GeoSite.dat", "ASN.mmdb", ".validate-x/rules.yaml", "CONFIG~1.JSO", "../outside.yaml", "/etc/rules.yaml", `rules\a.yaml`,
		"rules/../config.json", "rules/con.txt", "rules/a.", "rules/a ", "a:b", "rules//a.yaml", "",
	} {
		for _, key := range []string{"path", "PATH", "Path"} {
			input := `{"rule-providers":{"r":{"type":"http","url":"https://example.test/r.yaml",` + strconv.Quote(key) + `:` + strconv.Quote(path) + `}}}`
			if _, err := sanitizeKernelConfig(input); err == nil {
				t.Fatalf("保留或越界路径必须拒绝: %s=%q", key, path)
			}
		}
	}
	for _, rejected := range []string{
		`{"rule-providers":{"r":{"type":"http","url":"https://example.test/r.yaml","path":"rules/ok.yaml","PATH":"config.json"}}}`,
		`{"proxy-providers":{"sub":{"type":"http","url":"https://example.test/s.yaml","pAtH":7}}}`,
	} {
		if _, err := sanitizeKernelConfig(rejected); err == nil {
			t.Fatalf("任一大小写变体不合法都必须拒绝: %s", rejected)
		}
	}
	for _, accepted := range []string{
		`{"rule-providers":{"r":{"type":"http","url":"https://example.test/r.yaml","PATH":"./Rules/Legit.YAML"}}}`,
		`{"proxy-providers":{"ecy-panel-nodes":{"type":"file","path":"ecy-panel-nodes.json","payload":[{"name":"n","type":"direct"}]},"sub":{"type":"http","url":"https://example.test/s.yaml","Path":"providers/sub.yaml"}}}`,
		`{"rule-providers":{"inline":{"type":"inline","payload":["example.test"]}}}`,
	} {
		if _, err := sanitizeKernelConfig(accepted); err != nil {
			t.Fatalf("合法路径必须放行: %s: %v", accepted, err)
		}
	}
}

// 面板下发的 geox-url 与 provider 地址只收 https；本地 provider 没有地址不受影响，放行时面板的值原样落盘
func TestSanitizeKernelConfigRejectsPlaintextDownloads(t *testing.T) {
	for _, rejected := range []string{
		`{"geox-url":{"mmdb":"https://example.test/geoip.metadb","geosite":"http://example.test/GeoSite.dat"}}`,
		`{"geox-url":{"asn":" HTTP://example.test/ASN.mmdb"}}`,
		`{"proxy-providers":{"sub":{"type":"http","url":"http://example.test/nodes.yaml","path":"sub.yaml"}}}`,
		`{"proxy-providers":{"sub":{"type":"http","URL":"http://example.test/nodes.yaml","path":"sub.yaml"}}}`,
		`{"rule-providers":{"ads":{"type":"http","Url":"http://example.test/ads.yaml","path":"ads.yaml","behavior":"domain"}}}`,
		`{"rule-providers":{"ads":{"type":"http","url":7,"path":"ads.yaml"}}}`,
	} {
		if _, err := sanitizeKernelConfig(rejected); err == nil {
			t.Fatalf("明文下载地址必须拒绝: %s", rejected)
		}
	}
	for _, accepted := range []string{
		`{"geox-url":{"mmdb":"https://example.test/geoip.metadb","geosite":"HTTPS://example.test/GeoSite.dat"}}`,
		`{"proxy-providers":{"sub":{"type":"http","url":"https://example.test/nodes.yaml","path":"sub.yaml"},"local":{"type":"file","path":"local.yaml"}}}`,
		`{"rule-providers":{"ads":{"type":"http","url":"https://example.test/ads.yaml","path":"ads.yaml"},"inline":{"type":"inline","url":"","payload":["example.test"]}}}`,
	} {
		out, err := sanitizeKernelConfig(accepted)
		if err != nil {
			t.Fatalf("https 与本地 provider 必须放行: %s: %v", accepted, err)
		}
		var in, got map[string]any
		if json.Unmarshal([]byte(accepted), &in) != nil || json.Unmarshal([]byte(out), &got) != nil {
			t.Fatalf("配置无法解析: %s", out)
		}
		for key, value := range in {
			want, _ := json.Marshal(value)
			have, _ := json.Marshal(got[key])
			if string(want) != string(have) {
				t.Fatalf("面板下发的 %s 不得改写: %s", key, out)
			}
		}
	}
}

func TestPeerIdentityReportsKernelVerifiedExecutable(t *testing.T) {
	dir, err := os.MkdirTemp("", "peer-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: filepath.Join(dir, "p.sock"), Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	client, err := net.Dial("unix", filepath.Join(dir, "p.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	conn, err := listener.AcceptUnix()
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	caller, err := peerIdentity(conn, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	defer caller.close()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if caller.pid != os.Getpid() || caller.user != strconv.Itoa(os.Geteuid()) || realPath(caller.exe) != realPath(self) {
		t.Fatalf("对端身份必须取自内核: pid=%d uid=%s exe=%s", caller.pid, caller.user, caller.exe)
	}
}

func handshakePair(t *testing.T) (*net.UnixConn, *net.UnixConn, *peer) {
	t.Helper()
	dir, err := os.MkdirTemp("", "handshake-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: filepath.Join(dir, "h.sock"), Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	client, err := net.DialUnix("unix", nil, listener.Addr().(*net.UnixAddr))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { client.Close() })
	server, err := listener.AcceptUnix()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { server.Close() })
	caller, err := peerIdentity(server, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(caller.close)
	return server, client, caller
}

func handshakeNonce(t *testing.T, line string) string {
	t.Helper()
	var greeting struct {
		OK    bool              `json:"ok"`
		Error string            `json:"error"`
		Data  map[string]string `json:"data"`
	}
	if err := json.Unmarshal([]byte(line), &greeting); err != nil || greeting.OK || greeting.Error == "" || greeting.Data["nonce"] == "" {
		t.Errorf("握手行必须带随机数，且让旧版 GUI 按失败应答提示: %q, %v", line, err)
	}
	return greeting.Data["nonce"]
}

func TestRequestRequiresHandshakeNonceFromSameCaller(t *testing.T) {
	for _, c := range []struct {
		name   string
		send   func(nonce string) string
		half   bool
		accept bool
	}{
		{"握手后由同一调用方发出", func(nonce string) string { return `{"command":"ping","nonce":"` + nonce + `"}` + "\n" }, false, true},
		{"随机数不符", func(string) string { return `{"command":"ping","nonce":"guess"}` + "\n" }, false, false},
		{"请求后还有数据", func(nonce string) string { return `{"command":"ping","nonce":"` + nonce + `"}` + "\n{}\n" }, false, false},
		{"写完请求即关闭写端", func(nonce string) string { return `{"command":"ping","nonce":"` + nonce + `"}` }, true, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			server, client, caller := handshakePair(t)
			done := make(chan struct{})
			go func() {
				defer close(done)
				line, err := bufio.NewReader(client).ReadString('\n')
				if err != nil {
					t.Error(err)
					return
				}
				client.Write([]byte(c.send(handshakeNonce(t, line))))
				if c.half {
					client.CloseWrite()
				}
			}()
			req, ok := readRequest(server, caller)
			<-done
			if ok != c.accept || (ok && req.Command != "ping") {
				t.Fatalf("期望受理=%v，实际 %v %+v", c.accept, ok, req)
			}
		})
	}
}

func TestLegacyClientGetsSingleFailureLine(t *testing.T) {
	server, client, caller := handshakePair(t)
	if _, err := client.Write([]byte(`{"command":"ping","pid":1}` + "\n")); err != nil {
		t.Fatal(err)
	}
	if _, ok := readRequest(server, caller); ok {
		t.Fatal("握手前预写的请求不能受理")
	}
	server.Close()
	client.SetReadDeadline(time.Now().Add(5 * time.Second))
	all, err := io.ReadAll(client)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(string(all), "\n"), "\n")
	if len(lines) != 1 {
		t.Fatalf("旧版 GUI 读到 EOF 前只能收到握手这一行: %q", all)
	}
	handshakeNonce(t, lines[0])
}

func TestKernelDownloadMustStayInOfficialReleases(t *testing.T) {
	for _, raw := range []string{
		downloadPrefix + "../../../../evil/repo/releases/download/v1.19.33/mihomo.gz",
		downloadPrefix + "%2e%2e/%2e%2e/%2e%2e/%2e%2e/evil/repo/releases/download/v1.19.33/mihomo.gz",
		downloadPrefix + "v1.19.33/./mihomo.gz",
		"https://user@github.com/MetaCubeX/mihomo/releases/download/v1.19.33/mihomo.gz",
		"https://github.com:8443/MetaCubeX/mihomo/releases/download/v1.19.33/mihomo.gz",
		"https://github.com/MetaCubeX/mihomo-fork/releases/download/v1.19.33/mihomo.gz",
	} {
		if officialDownload(raw) {
			t.Fatalf("不得下载官方发布路径以外的内核: %s", raw)
		}
	}
	if !officialDownload(downloadPrefix + "v1.19.33/mihomo-linux-amd64-compatible-v1.19.33.gz") {
		t.Fatal("官方发布资产必须可下载")
	}
}
