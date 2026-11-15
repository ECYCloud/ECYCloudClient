//go:build linux

package main

import (
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// SO_PEERCRED 只记连接时的 pid：持有该 pid 的进程若晚于连接创建、或校验后已退出，都说明 pid 不再指向原调用方
func TestPeerIdentityRejectsReusedOrExitedPid(t *testing.T) {
	const marker = "ECYCLOUD_TEST_PEER_PID_SOCKET"
	if socket := os.Getenv(marker); socket != "" {
		conn, err := net.Dial("unix", socket)
		if err != nil {
			os.Exit(2)
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
	socket := filepath.Join(dir, "p.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socket, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	before := time.Now()
	time.Sleep(100 * time.Millisecond)
	child := exec.Command(os.Args[0], "-test.run=^TestPeerIdentityRejectsReusedOrExitedPid$")
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
	if caller, err := peerIdentity(conn, before); err == nil {
		caller.close()
		t.Fatal("晚于连接创建的进程不能被认作调用方")
	}
	caller, err := peerIdentity(conn, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	defer caller.close()
	if caller.pid != child.Process.Pid {
		t.Fatalf("对端 pid 不符: %d", caller.pid)
	}
	if err := caller.confirm(conn); err != nil {
		t.Fatalf("调用方存活时应通过复核: %v", err)
	}
	conn.Write([]byte{1})
	child.Wait()
	if err := caller.confirm(conn); err == nil {
		t.Fatal("调用方退出后不能再通过复核")
	}
}

func TestKernelCredentialFailsClosed(t *testing.T) {
	previousUID, previousGID := kernelUID, kernelGID
	t.Cleanup(func() { kernelUID, kernelGID = previousUID, previousGID })
	for _, ids := range [][2]int{{0, 0}, {-1, -1}, {1234, 0}, {0, 1234}} {
		kernelUID, kernelGID = ids[0], ids[1]
		if err := applyKernelCredential(exec.Command("unused")); err == nil {
			t.Fatalf("不可信账户 %v 不应回退到 root", ids)
		}
	}
	kernelUID, kernelGID = 1234, 1234
	cmd := exec.Command("unused")
	if err := applyKernelCredential(cmd); err != nil {
		t.Fatal(err)
	}
	if cmd.SysProcAttr.Credential.Uid != 1234 || cmd.SysProcAttr.Credential.Gid != 1234 || len(cmd.SysProcAttr.AmbientCaps) != 2 {
		t.Fatal("内核必须使用受限用户和两项网络权限")
	}
}
