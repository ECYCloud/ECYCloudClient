//go:build darwin && cgo

package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// kern.procargs2 里的可执行路径存在对端进程自己的内存里：改写它冒充官方 GUI 不能骗过 helper。
func TestPeerIdentityIgnoresSpoofedProcessArguments(t *testing.T) {
	const marker = "ECYCLOUD_TEST_SPOOF_SOCKET"
	const spoofed = "/Applications/ECYCloud.app/Contents/MacOS/ECYCloud"
	if socket := os.Getenv(marker); socket != "" {
		raw, err := unix.SysctlRaw("kern.procargs2", os.Getpid())
		if err != nil || len(raw) <= 4 {
			os.Exit(2)
		}
		current := raw[4:]
		current = current[:bytes.IndexByte(current, 0)]
		argv0 := unsafe.Pointer(unsafe.StringData(os.Args[0]))
		for offset := -len(current) - 1; offset > -4096; offset-- {
			execPath := unsafe.Slice((*byte)(unsafe.Add(argv0, offset)), len(current))
			if bytes.Equal(execPath, current) {
				if len(execPath) < len(spoofed) {
					os.Exit(3)
				}
				clear(execPath)
				copy(execPath, spoofed)
				break
			}
		}
		conn, err := net.Dial("unix", socket)
		if err != nil {
			os.Exit(3)
		}
		var ack [1]byte
		conn.Read(ack[:])
		os.Exit(0)
	}
	dir, err := os.MkdirTemp("", "peer-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socket := filepath.Join(dir, "s.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socket, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	child := exec.Command(os.Args[0], "-test.run=^TestPeerIdentityIgnoresSpoofedProcessArguments$")
	child.Env = append(os.Environ(), marker+"="+socket)
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
	raw, err := unix.SysctlRaw("kern.procargs2", child.Process.Pid)
	if err != nil || !strings.HasPrefix(string(raw[4:]), spoofed+"\x00") {
		t.Fatalf("测试前提不成立，procargs2 未被改写: %q", raw[4:min(len(raw), 80)])
	}
	caller, err := peerIdentity(conn, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if realPath(caller.exe) == realPath(spoofed) {
		t.Fatal("helper 采信了对端自行改写的可执行路径")
	}
	self, _ := os.Executable()
	if realPath(caller.exe) != realPath(self) {
		t.Fatalf("应识别出真实的可执行文件: %s", caller.exe)
	}
}

const handshakeRoleEnv = "ECYCLOUD_TEST_HANDSHAKE_ROLE"

func answerHandshake(conn io.ReadWriter) {
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		os.Exit(2)
	}
	var greeting struct {
		Data map[string]string `json:"data"`
	}
	json.Unmarshal([]byte(line), &greeting)
	conn.Write([]byte(`{"command":"ping","nonce":"` + greeting.Data["nonce"] + `"}` + "\n"))
	time.Sleep(5 * time.Second)
	os.Exit(0)
}

// write 角色的 fd 3 是兄弟进程传下来的同一条连接：要等服务端核对完连接方再动手，且不能登记进
// kqueue，内核把收发、poll 与 kevent 登记都记成最后操作者
func playHandshakeRole(role, socket string) {
	if role == "write" {
		time.Sleep(time.Second)
		answerHandshake(os.NewFile(3, "conn"))
	}
	conn, err := net.Dial("unix", socket)
	if err != nil {
		os.Exit(2)
	}
	file, err := conn.(*net.UnixConn).File()
	if err != nil {
		os.Exit(2)
	}
	if role == "self" {
		answerHandshake(conn)
	}
	if role == "prewrite-exec" {
		conn.Write([]byte(`{"command":"ping","nonce":"guess"}` + "\n"))
	}
	if role == "delegate" || role == "sibling-exec" {
		child := exec.Command(os.Args[0], "-test.run=^TestRequestWrittenByAnotherProcessRejected$")
		child.Env = append(os.Environ(), handshakeRoleEnv+"=write")
		child.ExtraFiles = []*os.File{file}
		if err := child.Start(); err != nil {
			os.Exit(2)
		}
	}
	if role == "prewrite-exec" || role == "sibling-exec" {
		if _, err := unix.FcntlInt(file.Fd(), unix.F_SETFD, 0); err != nil {
			os.Exit(2)
		}
		syscall.Exec("/bin/sleep", []string{"sleep", "5"}, os.Environ())
		os.Exit(2)
	}
	time.Sleep(5 * time.Second)
	os.Exit(0)
}

// 连接后 exec 成另一映像、或由共享连接的其它进程读握手并代写请求，都不能当成通过校验的调用方
func TestRequestWrittenByAnotherProcessRejected(t *testing.T) {
	if role := os.Getenv(handshakeRoleEnv); role != "" {
		playHandshakeRole(role, os.Getenv("ECYCLOUD_TEST_HANDSHAKE_SOCKET"))
	}
	for _, c := range []struct {
		role   string
		exe    string
		accept bool
	}{
		{"self", "", true},
		{"delegate", "", false},
		{"prewrite-exec", "/bin/sleep", false},
		{"sibling-exec", "/bin/sleep", false},
	} {
		t.Run(c.role, func(t *testing.T) {
			dir, err := os.MkdirTemp("", "handshake-")
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { os.RemoveAll(dir) })
			socket := filepath.Join(dir, "h.sock")
			listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socket, Net: "unix"})
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			child := exec.Command(os.Args[0], "-test.run=^TestRequestWrittenByAnotherProcessRejected$")
			child.Env = append(os.Environ(), handshakeRoleEnv+"="+c.role, "ECYCLOUD_TEST_HANDSHAKE_SOCKET="+socket)
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
			time.Sleep(500 * time.Millisecond)
			caller, err := peerIdentity(conn, time.Now())
			if err != nil {
				t.Fatal(err)
			}
			if c.exe != "" && realPath(caller.exe) != realPath(c.exe) {
				t.Fatalf("exec 之后审计令牌应解析到新映像: %s", caller.exe)
			}
			if _, ok := readRequest(conn, caller); ok != c.accept {
				t.Fatalf("期望受理=%v，实际 %v", c.accept, ok)
			}
		})
	}
}
