//go:build darwin || linux

package main

import (
	"encoding/json"
	"net"
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
	if err := verifyGUICaller(os.Getpid()); err == nil {
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
	pid, uid, err := peerIdentity(conn)
	if err != nil || pid != child.Process.Pid || uid != "65534" {
		t.Fatalf("必须采用操作系统记录的 UID/PID: %d, %s, %v", pid, uid, err)
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
