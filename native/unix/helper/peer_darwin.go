//go:build darwin

package main

import (
	"bytes"
	"fmt"
	"net"
	"os/exec"

	"golang.org/x/sys/unix"
)

// 请求体里的 pid 是调用方自己填的、不可信，只能取内核记录的对端凭据
func peerPID(conn *net.UnixConn) (int, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return 0, fmt.Errorf("获取连接底层句柄失败: %w", err)
	}

	var pid int
	var pidErr error
	if err := raw.Control(func(fd uintptr) {
		pid, pidErr = unix.GetsockoptInt(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERPID)
	}); err != nil {
		return 0, fmt.Errorf("读取对端凭据失败: %w", err)
	}
	if pidErr != nil {
		return 0, fmt.Errorf("读取对端凭据失败: %w", pidErr)
	}
	return pid, nil
}

// macOS 没有 /proc，proc_pidpath 又要 cgo。kern.procargs2 的布局是
// [4 字节 argc][可执行文件路径\0]...，取第一段即可，纯 Go 就能拿到。
func processExePath(pid int) (string, error) {
	raw, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil {
		return "", fmt.Errorf("查询调用方可执行文件失败: %w", err)
	}
	if len(raw) <= 4 {
		return "", fmt.Errorf("进程 %d 的启动信息不完整", pid)
	}

	path := raw[4:]
	if end := bytes.IndexByte(path, 0); end >= 0 {
		path = path[:end]
	}
	if len(path) == 0 {
		return "", fmt.Errorf("进程 %d 没有可执行文件路径", pid)
	}
	return string(path), nil
}

// utun 只认 root，macOS 也没有 capability 可降权
func resolveKernelUser() (int, int) { return 0, 0 }

func applyKernelCredential(_ *exec.Cmd) {}
