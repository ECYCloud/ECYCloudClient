//go:build windows

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
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

func TestSessionCleanupBeforeAccountHandoff(t *testing.T) {
	t.Setenv("ProgramData", t.TempDir())
	if err := os.MkdirAll(runDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath(), []byte("old-secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	s := newServer()
	s.owner, s.watched = "account-a", os.Getpid()
	s.kernel.logs.append("old-account-log")
	if err := s.resetSession(); err != nil {
		t.Fatal(err)
	}
	if s.owner != "" || s.watched != 0 {
		t.Fatal("清理成功后才可释放会话")
	}
	if _, err := os.Stat(configPath()); !os.IsNotExist(err) {
		t.Fatalf("旧配置未删除: %v", err)
	}
	if len(s.kernel.status(0).LogLines) != 0 {
		t.Fatal("旧日志不能交给新账号")
	}
	if err := s.lockSession(os.Getpid(), "account-b"); err != nil {
		t.Fatal(err)
	}
	s.mu.RUnlock()
	if s.owner != "account-b" {
		t.Fatal("清理后新账号应可接管")
	}
}

func TestFailedCleanupKeepsOwner(t *testing.T) {
	t.Setenv("ProgramData", t.TempDir())
	if err := os.MkdirAll(runDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(snapshotPath(), []byte("invalid snapshot"), 0o600); err != nil {
		t.Fatal(err)
	}
	s := newServer()
	s.owner, s.watched = "account-a", os.Getpid()
	if err := s.resetSession(); err == nil {
		t.Fatal("无效代理快照必须阻止会话转移")
	}
	if _, err := os.Stat(snapshotPath()); err != nil {
		t.Fatal("失败时必须保留恢复快照")
	}
	if err := s.lockSession(os.Getpid(), "account-b"); err == nil {
		s.mu.RUnlock()
		t.Fatal("清理失败不能转移会话")
	}
}

func TestPanelAccountCleanupRetainsSystemOwner(t *testing.T) {
	t.Setenv("ProgramData", t.TempDir())
	if err := os.MkdirAll(runDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath(), []byte("old-account-secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	s := newServer()
	s.owner, s.watched = "account-a", os.Getpid()
	s.kernel.logs.append("old-account-log")
	if _, err := s.dispatch(request{Command: "kernel.clear"}, os.Getpid(), "account-a"); err != nil {
		t.Fatal(err)
	}
	if s.owner != "account-a" || s.watched != os.Getpid() {
		t.Fatal("面板账户清理不能释放系统账号独占权")
	}
	if _, err := os.Stat(configPath()); !os.IsNotExist(err) {
		t.Fatalf("旧配置未删除: %v", err)
	}
	if len(s.kernel.status(0).LogLines) != 0 {
		t.Fatal("旧日志未清理")
	}
	if _, err := s.dispatch(request{Command: "kernel.clear"}, os.Getpid(), "account-a"); err != nil {
		t.Fatalf("重复清理应可成功: %v", err)
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

func TestSessionCleanupConfinedToRunDirectory(t *testing.T) {
	base := t.TempDir()
	run := filepath.Join(base, "run")
	if err := os.MkdirAll(filepath.Join(run, "providers"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"config.json", "cache.db", "providers/private.txt"} {
		if err := os.WriteFile(filepath.Join(run, name), []byte("old-account-secret"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	sibling := filepath.Join(base, "keep")
	if err := os.WriteFile(sibling, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := clearSessionFiles(base); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(run); !os.IsNotExist(err) {
		t.Fatalf("旧会话目录仍存在: %v", err)
	}
	if content, err := os.ReadFile(sibling); err != nil || string(content) != "keep" {
		t.Fatalf("不能删除运行目录之外的数据: %q, %v", content, err)
	}
	outside := t.TempDir()
	protected := filepath.Join(outside, "protected")
	if err := os.WriteFile(protected, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, run); err != nil {
		t.Logf("当前环境无法创建目录链接，链接子项未验证: %v", err)
		return
	}
	if err := clearSessionFiles(base); err != nil {
		t.Fatal(err)
	}
	if content, err := os.ReadFile(protected); err != nil || string(content) != "keep" {
		t.Fatalf("清理不能跟随旧会话目录链接: %q, %v", content, err)
	}
}

func TestNormalExitRetainsBoundProvidersButDropsRuntimeSecrets(t *testing.T) {
	base := t.TempDir()
	run := filepath.Join(base, "run")
	if err := os.MkdirAll(filepath.Join(run, "providers"), 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"config.json", "config.check.json", "proxy-snapshot.json", "cache.db", "providers/rules.mrs"} {
		if err := os.WriteFile(filepath.Join(run, name), []byte("test"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(base, ".cache-owner"), []byte("user\n"+strings.Repeat("a", 64)), 0600); err != nil {
		t.Fatal(err)
	}
	if err := clearSessionFiles(base, true); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"config.json", "config.check.json", "proxy-snapshot.json"} {
		if _, err := os.Stat(filepath.Join(run, name)); !os.IsNotExist(err) {
			t.Fatalf("运行密钥残留: %s", name)
		}
	}
	for _, name := range []string{"cache.db", "providers/rules.mrs"} {
		if _, err := os.Stat(filepath.Join(run, name)); err != nil {
			t.Fatalf("可用缓存丢失: %s %v", name, err)
		}
	}
	if err := clearSessionFiles(base); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"run", ".cache-owner"} {
		if _, err := os.Stat(filepath.Join(base, name)); !os.IsNotExist(err) {
			t.Fatalf("退出账号仍残留: %s", name)
		}
	}
}

func TestDifferentOSUserCannotReadPreviousBoundCache(t *testing.T) {
	t.Setenv("ProgramData", t.TempDir())
	if err := os.MkdirAll(runDir(), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dataDir(), ".cache-owner"), []byte("account-a\n"+strings.Repeat("a", 64)), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(runDir(), "private-provider"), []byte("old-account"), 0600); err != nil {
		t.Fatal(err)
	}
	s := newServer()
	if err := s.lockSession(os.Getpid(), "account-b"); err != nil {
		t.Fatal(err)
	}
	s.mu.RUnlock()
	if _, err := os.Stat(filepath.Join(runDir(), "private-provider")); !os.IsNotExist(err) {
		t.Fatal("其他系统账号获得旧缓存")
	}
	if err := s.bindCache("../escape", "account-b"); err == nil {
		t.Fatal("缓存标识被当成路径")
	}
}
