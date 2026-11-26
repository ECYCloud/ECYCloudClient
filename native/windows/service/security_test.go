//go:build windows

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
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

func TestPanelProviderWriteReplacesFileAndRejectsHardLinks(t *testing.T) {
	t.Setenv("ProgramData", t.TempDir())
	if err := os.MkdirAll(runDir(), 0700); err != nil {
		t.Fatal(err)
	}
	config := `{"proxy-providers":{"ecy-panel-nodes":{"type":"file","path":"ecy-panel-nodes.json","payload":[{"name":"node-1","type":"direct"}]}}}`
	if err := writePanelProviders(config); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(runDir(), "ecy-panel-nodes.json")
	old, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer old.Close()
	if err := writePanelProviders(strings.ReplaceAll(config, "node-1", "node-2")); err == nil {
		t.Fatal("Windows 不允许替换未授予删除共享的已打开文件")
	}
	oldContent := make([]byte, 256)
	n, err := old.Read(oldContent)
	if err != nil || !strings.Contains(string(oldContent[:n]), "node-1") {
		t.Fatalf("不能截断内核仍在读取的旧文件: %s, %v", oldContent[:n], err)
	}
	old.Close()
	if err := writePanelProviders(strings.ReplaceAll(config, "node-1", "node-2")); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(content), "node-2") {
		t.Fatalf("节点文件更新失败: %s, %v", content, err)
	}
	link := filepath.Join(runDir(), "protected")
	if err := os.Link(path, link); err != nil {
		t.Fatal(err)
	}
	if err := writePanelProviders(config); err == nil {
		t.Fatal("多硬链接节点文件必须拒绝")
	}
	if content, err := os.ReadFile(link); err != nil || !strings.Contains(string(content), "node-2") {
		t.Fatal("不能修改硬链接指向的文件")
	}
	entries, err := os.ReadDir(runDir())
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".ecy-provider-") {
			t.Fatal("节点文件更新残留临时文件")
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

func TestReadRunFileConfinement(t *testing.T) {
	base := t.TempDir()
	t.Setenv("ProgramData", base)
	if err := os.MkdirAll(runDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(runDir(), "rules.txt"), []byte("DOMAIN,example.com"), 0o600); err != nil {
		t.Fatal(err)
	}
	kernel := newKernelManager()
	if content, err := kernel.read("./rules.txt"); err != nil || content != "DOMAIN,example.com" {
		t.Fatalf("合法规则文件不能读取: %q, %v", content, err)
	}
	if err := os.WriteFile(filepath.Join(runDir(), "rules.txt:stream"), []byte("private stream"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"../outside", `C:\Windows\win.ini`, `\\server\share\file`, "rules.txt:stream", "."} {
		if _, err := kernel.read(path); err == nil {
			t.Errorf("越界路径应被拒绝: %q", path)
		}
	}
	outside := filepath.Join(base, "outside.txt")
	if err := os.WriteFile(outside, []byte("private"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(runDir(), "escape.txt")
	if err := os.Symlink(outside, link); err != nil {
		t.Logf("当前账户不能创建符号链接: %v", err)
	} else if _, err := kernel.read("escape.txt"); err == nil {
		t.Fatal("不能通过链接越出运行目录")
	}
	if err := os.WriteFile(filepath.Join(runDir(), "large.txt"), []byte(strings.Repeat("x", maxRunFileBytes+1)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := kernel.read("large.txt"); err == nil {
		t.Fatal("不能读取超过大小上限的文件")
	}
}

func TestUntrustedCallerDenied(t *testing.T) {
	if err := verifyGUICaller(os.Getpid()); err == nil {
		t.Fatal("非官方程序不能调用服务")
	}
}

func TestCallerCreatedAfterConnectionDenied(t *testing.T) {
	if _, _, err := guiCallerSID(os.Getpid(), time.Now().Add(-time.Hour)); err == nil || !strings.Contains(err.Error(), "晚于本次连接") {
		t.Fatalf("晚于连接创建的进程只可能复用了连接时的 PID，必须拒绝: %v", err)
	}
	if _, _, err := guiCallerSID(os.Getpid(), time.Now()); err == nil || !strings.Contains(err.Error(), "非官方客户端") {
		t.Fatalf("创建时间合规后仍须核对可执行文件路径: %v", err)
	}
	if _, _, err := guiCallerSID(0x7ffffff0, time.Now()); err == nil {
		t.Fatal("打不开的进程必须拒绝")
	}
}

func TestAcceptTimeSurvivesClockSteps(t *testing.T) {
	started := serviceStarted.Round(0)
	if got := wallClockAt(started.Add(time.Second-time.Hour), time.Second); !got.Equal(started.Add(time.Second)) {
		t.Fatalf("墙钟回拨后应按服务启动时的墙钟加单调时长推算: %v", got)
	}
	if got := wallClockAt(started.Add(time.Hour), time.Second); !got.Equal(started.Add(time.Hour)) {
		t.Fatalf("墙钟前拨后应取当前墙钟: %v", got)
	}
}

func TestSessionResetReleasesOwnerAndKeepsSessionCache(t *testing.T) {
	t.Setenv("ProgramData", t.TempDir())
	activeSession = strings.Repeat("a", 64)
	defer func() { activeSession = "" }()
	if err := os.MkdirAll(runDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"config.json", "cache.db"} {
		if err := os.WriteFile(filepath.Join(runDir(), name), []byte("old-secret"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	s := newServer()
	s.owner, s.watched = "account-a", os.Getpid()
	s.kernel.logs.append("old-account-log")
	if err := s.resetSession(); err != nil {
		t.Fatal(err)
	}
	if s.owner != "" || s.watched != 0 || activeSession != "" {
		t.Fatal("内核停下后应释放系统账号独占与会话绑定")
	}
	dir := filepath.Join(runRoot(), strings.Repeat("a", 64))
	if _, err := os.Stat(filepath.Join(dir, "config.json")); !os.IsNotExist(err) {
		t.Fatalf("运行密钥未删除: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "cache.db")); err != nil {
		t.Fatalf("同一会话的缓存丢失: %v", err)
	}
	if len(s.kernel.status(0).LogLines) != 0 {
		t.Fatal("旧日志不能交给新账号")
	}
	if err := s.lockSession(os.Getpid(), "account-b"); err != nil {
		t.Fatal(err)
	}
	s.mu.RUnlock()
	if s.owner != "account-b" {
		t.Fatal("新系统账号应可接管")
	}
}

func TestProxyRestoreFailureDoesNotBlockSessionEnd(t *testing.T) {
	t.Setenv("ProgramData", t.TempDir())
	if err := os.MkdirAll(runRoot(), 0o700); err != nil {
		t.Fatal(err)
	}
	snapshot := `{"user_sid":"S-1-5-21-0-0-0-1001"}`
	path := snapshotPath("S-1-5-21-0-0-0-1001")
	if err := os.WriteFile(path, []byte(snapshot), 0o600); err != nil {
		t.Fatal(err)
	}
	s := newServer()
	s.owner, s.watched = "account-a", os.Getpid()
	if _, err := s.dispatch(request{Command: "kernel.clear"}, os.Getpid(), "account-a"); err != nil {
		t.Fatalf("代理还原失败不能让退出失败: %v", err)
	}
	if content, err := os.ReadFile(path); err != nil || string(content) != snapshot {
		t.Fatalf("未还原的代理快照必须保留: %q, %v", content, err)
	}
}

func TestPanelAccountEndRetainsSystemOwner(t *testing.T) {
	t.Setenv("ProgramData", t.TempDir())
	activeSession = strings.Repeat("a", 64)
	defer func() { activeSession = "" }()
	if err := os.MkdirAll(runDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"config.json", "ecy-panel-nodes.json", "cache.db"} {
		if err := os.WriteFile(filepath.Join(runDir(), name), []byte("old-account"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	touchLastUsed(runDir())
	dir := runDir()
	s := newServer()
	s.owner, s.watched = "account-a", os.Getpid()
	s.kernel.logs.append("old-account-log")
	if _, err := s.dispatch(request{Command: "kernel.clear", CacheKey: strings.Repeat("a", 64)}, os.Getpid(), "account-a"); err != nil {
		t.Fatal(err)
	}
	if s.owner != "account-a" || s.watched != os.Getpid() {
		t.Fatal("面板账户退出不能释放系统账号独占权")
	}
	for _, name := range []string{"config.json", "ecy-panel-nodes.json"} {
		if _, err := os.Stat(filepath.Join(dir, name)); !os.IsNotExist(err) {
			t.Fatalf("退出后带节点凭据的配置仍在: %s %v", name, err)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "cache.db")); err != nil {
		t.Fatalf("退出不能删掉留给同账号复用的缓存: %v", err)
	}
	if len(s.kernel.status(0).LogLines) != 0 {
		t.Fatal("旧日志未清理")
	}
	if _, err := s.dispatch(request{Command: "kernel.read", Path: "config.json"}, os.Getpid(), "account-a"); err == nil {
		t.Fatal("退出后不能再读旧账户运行文件")
	}
	if _, err := s.dispatch(request{Command: "kernel.clear"}, os.Getpid(), "account-a"); err != nil {
		t.Fatalf("重复退出应可成功: %v", err)
	}
}

func TestServiceJobKillsChildOnParentExit(t *testing.T) {
	const marker = "ECYCLOUD_TEST_JOB_PROCESS"
	switch os.Getenv(marker) {
	case "child":
		time.Sleep(time.Minute)
		os.Exit(0)
	case "parent":
		if err := containServiceProcesses(); err != nil {
			t.Fatal(err)
		}
		child := exec.Command(os.Args[0], "-test.run=^TestServiceJobKillsChildOnParentExit$")
		child.Env = append(os.Environ(), marker+"=child")
		if err := child.Start(); err != nil {
			t.Fatal(err)
		}
		fmt.Println(child.Process.Pid)
		time.Sleep(time.Minute)
		os.Exit(0)
	}
	parent := exec.Command(os.Args[0], "-test.run=^TestServiceJobKillsChildOnParentExit$")
	parent.Env = append(os.Environ(), marker+"=parent")
	output, err := parent.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	parent.Stderr = os.Stderr
	if err := parent.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { parent.Process.Kill(); parent.Wait() })
	line, err := bufio.NewReader(output).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(line))
	if err != nil {
		t.Fatal(err)
	}
	child, err := windows.OpenProcess(windows.SYNCHRONIZE|windows.PROCESS_TERMINATE, false, uint32(pid))
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(child)
	defer windows.TerminateProcess(child, 1)
	if err := parent.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	result, err := windows.WaitForSingleObject(child, 5000)
	if err != nil || result != windows.WAIT_OBJECT_0 {
		t.Fatalf("服务异常退出后子进程仍存活: %d, %v", result, err)
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

func TestProxySnapshotsArePerSystemAccount(t *testing.T) {
	t.Setenv("ProgramData", t.TempDir())
	if err := os.MkdirAll(runRoot(), 0o700); err != nil {
		t.Fatal(err)
	}
	other := snapshotPath("S-1-5-21-1-1-1-1002")
	if err := os.WriteFile(other, []byte(`{"user_sid":"S-1-5-21-1-1-1-1002"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	current := user.User.Sid.String()
	p := newProxyManager()
	state, err := p.state(current)
	if err != nil || state.SnapshotPresent {
		t.Fatalf("其它系统账号的快照不能挡住或冒充当前账号: %+v %v", state, err)
	}
	if err := p.restore(current); err != nil {
		t.Fatalf("没有自己的快照时还原应直接成功: %v", err)
	}
	if _, err := os.Stat(other); err != nil {
		t.Fatalf("还原只能动自己的快照: %v", err)
	}
	if _, err := p.state("../escape"); err == nil {
		t.Fatal("系统账号标识被当成路径")
	}
	if !strings.HasSuffix(other, "proxy-snapshot-S-1-5-21-1-1-1-1002.json") {
		t.Fatalf("快照文件名必须带 SID: %s", other)
	}
}

func TestLogonRestoresDeferredProxiesExceptActiveOwner(t *testing.T) {
	t.Setenv("ProgramData", t.TempDir())
	if err := os.MkdirAll(runRoot(), 0o700); err != nil {
		t.Fatal(err)
	}
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	current := user.User.Sid.String()
	key, err := openInternetSettings(current, registry.QUERY_VALUE)
	if err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(captureSnapshot(key, current, os.Getpid()))
	key.Close()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(snapshotPath(current), data, 0o600); err != nil {
		t.Fatal(err)
	}
	offline := snapshotPath("S-1-5-21-0-0-0-1001")
	if err := os.WriteFile(offline, []byte(`{"user_sid":"S-1-5-21-0-0-0-1001"}`), 0o600); err != nil {
		t.Fatal(err)
	}

	s := newServer()
	s.owner = current
	s.restoreDeferredProxies()
	if _, err := os.Stat(snapshotPath(current)); err != nil {
		t.Fatalf("正在使用客户端的账号的快照不能被登录通知还原: %v", err)
	}
	s.owner = ""
	s.restoreDeferredProxies()
	if _, err := os.Stat(snapshotPath(current)); !os.IsNotExist(err) {
		t.Fatalf("已登录账号的残留快照应在登录通知后还原: %v", err)
	}
	if _, err := os.Stat(offline); err != nil {
		t.Fatalf("注册表未加载的账号快照必须保留到其登录: %v", err)
	}
}

func TestBindingReusesAccountDirectoryAndReplacesOtherAccount(t *testing.T) {
	t.Setenv("ProgramData", t.TempDir())
	dataDirReady.Store(false)
	t.Cleanup(func() { dataDirReady.Store(false) })
	defer func() { activeSession = "" }()
	s := newServer()
	bind := func(key string) {
		if _, err := s.dispatch(request{Command: "kernel.bind", CacheKey: key}, os.Getpid(), "account"); err != nil {
			t.Fatal(err)
		}
	}
	accountA, accountB := strings.Repeat("a", 64), strings.Repeat("b", 64)
	bind(accountA)
	if err := os.WriteFile(filepath.Join(runDir(), "cache.db"), []byte("a"), 0o600); err != nil {
		t.Fatal(err)
	}
	s.kernel.logs.append("account-a-log")
	bind(accountA)
	if len(s.kernel.status(0).LogLines) != 1 {
		t.Fatal("同账号再次绑定不能替换内核")
	}
	bind(accountB)
	if len(s.kernel.status(0).LogLines) != 0 || runDir() != filepath.Join(runRoot(), accountB) {
		t.Fatal("换账号必须替换内核并切到该账号目录")
	}
	if _, err := os.Stat(filepath.Join(runRoot(), accountA, "cache.db")); err != nil {
		t.Fatalf("30 天内用过的账号目录不能被回收: %v", err)
	}
	bind(accountA)
	if content, err := os.ReadFile(filepath.Join(runDir(), "cache.db")); err != nil || string(content) != "a" {
		t.Fatalf("同账号重新登录必须复用原目录的缓存: %q, %v", content, err)
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
