//go:build linux

package main

import (
	"fmt"
	"math"
	"net"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"syscall"

	"golang.org/x/sys/unix"
)

// 内核以它的身份运行：只带 CAP_NET_ADMIN / CAP_NET_RAW，不给整体 root
const kernelUserName = "ecycloud"

// 请求体里的 pid 是调用方自己填的、不可信，只能取内核记录的对端凭据
func peerPID(conn *net.UnixConn) (int, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return 0, fmt.Errorf("获取连接底层句柄失败: %w", err)
	}

	var cred *unix.Ucred
	var credErr error
	if err := raw.Control(func(fd uintptr) {
		cred, credErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	}); err != nil {
		return 0, fmt.Errorf("读取对端凭据失败: %w", err)
	}
	if credErr != nil {
		return 0, fmt.Errorf("读取对端凭据失败: %w", credErr)
	}
	return int(cred.Pid), nil
}

func processExePath(pid int) (string, error) {
	path, err := os.Readlink("/proc/" + strconv.Itoa(pid) + "/exe")
	if err != nil {
		return "", fmt.Errorf("查询调用方可执行文件失败: %w", err)
	}
	return path, nil
}

func parseKernelID(s string) (int, bool) {
	n, err := strconv.ParseUint(s, 10, 32)
	if err != nil || n > math.MaxInt32 {
		return 0, false
	}
	return int(n), true
}

// 用户缺失时退回 root（0,0），装包脚本没跑全时比降权失败更能连上网
func resolveKernelUser() (int, int) {
	account, err := user.Lookup(kernelUserName)
	if err != nil {
		return 0, 0
	}
	uid, ok := parseKernelID(account.Uid)
	if !ok {
		return 0, 0
	}
	gid, ok := parseKernelID(account.Gid)
	if !ok {
		return 0, 0
	}
	return uid, gid
}

func applyKernelCredential(cmd *exec.Cmd) {
	if kernelUID <= 0 || kernelGID < 0 || uint64(kernelUID) > math.MaxUint32 || uint64(kernelGID) > math.MaxUint32 {
		return
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Credential:  &syscall.Credential{Uid: uint32(kernelUID), Gid: uint32(kernelGID)},
		AmbientCaps: []uintptr{unix.CAP_NET_ADMIN, unix.CAP_NET_RAW},
	}
}
