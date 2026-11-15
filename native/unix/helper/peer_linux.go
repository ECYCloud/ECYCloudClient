//go:build linux

package main

import (
	"bytes"
	"fmt"
	"math"
	"net"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// 内核以它的身份运行：只带 CAP_NET_ADMIN / CAP_NET_RAW，不给整体 root
const kernelUserName = "ecycloud"

// /proc/<pid>/stat 的启动时间以 USER_HZ 计，内核对用户态固定为 100
const procClockTick = 10 * time.Millisecond

type peer struct {
	pid   int
	user  string
	exe   string
	pidfd int
	start uint64
}

// 请求体里的 pid 是调用方自己填的、不可信，只能取内核记录的对端凭据。
// SO_PEERCRED 只记连接时的 pid，读 /proc 期间它可能已被复用：先用 pidfd 钉住进程，再核对启动时间
func peerIdentity(conn *net.UnixConn, accepted time.Time) (*peer, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return nil, fmt.Errorf("获取连接底层句柄失败: %w", err)
	}

	var cred *unix.Ucred
	var credErr error
	pidfd := -1
	if err := raw.Control(func(fd uintptr) {
		cred, credErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
		if credErr == nil {
			if peerfd, err := unix.GetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_PEERPIDFD); err == nil {
				pidfd = peerfd
			}
		}
	}); err != nil {
		return nil, fmt.Errorf("读取对端凭据失败: %w", err)
	}
	if credErr != nil {
		return nil, fmt.Errorf("读取对端凭据失败: %w", credErr)
	}

	caller := &peer{pid: int(cred.Pid), user: strconv.FormatUint(uint64(cred.Uid), 10), pidfd: pidfd}
	// SO_PEERPIDFD 要 6.5 内核；按 pid 打开或没有 pidfd（5.3 前）时，靠下面的启动时间排除已被复用的 pid
	if caller.pidfd < 0 {
		opened, err := unix.PidfdOpen(caller.pid, 0)
		if err != nil && err != unix.ENOSYS {
			return nil, fmt.Errorf("打开调用方进程失败: %w", err)
		}
		if err == nil {
			caller.pidfd = opened
		}
	}
	if caller.start, err = processStart(caller.pid); err != nil {
		caller.close()
		return nil, err
	}
	if time.Duration(caller.start)*procClockTick > bootTimeAt(accepted) {
		caller.close()
		return nil, fmt.Errorf("调用方进程晚于本次连接创建，拒绝执行")
	}
	if caller.exe, err = processExePath(caller.pid); err != nil {
		caller.close()
		return nil, err
	}
	if err := caller.confirm(conn); err != nil {
		caller.close()
		return nil, err
	}
	return caller, nil
}

// pidfd 仍存活且启动时间未变，pid 才仍指向通过校验的那个进程
func (p *peer) confirm(*net.UnixConn) error {
	if p.pidfd >= 0 {
		if err := unix.PidfdSendSignal(p.pidfd, 0, nil, 0); err != nil {
			return fmt.Errorf("调用方进程已退出: %w", err)
		}
	}
	start, err := processStart(p.pid)
	if err != nil {
		return err
	}
	if start != p.start {
		return fmt.Errorf("调用方进程已被替换")
	}
	return nil
}

func (p *peer) close() {
	if p.pidfd >= 0 {
		unix.Close(p.pidfd)
		p.pidfd = -1
	}
}

func processStart(pid int) (uint64, error) {
	stat, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return 0, fmt.Errorf("查询调用方进程失败: %w", err)
	}
	// comm 可含空格与括号，只能从最后一个 ')' 往后数：其后第 20 段是第 22 列 starttime
	fields := bytes.Fields(stat[bytes.LastIndexByte(stat, ')')+1:])
	if len(fields) < 20 {
		return 0, fmt.Errorf("进程 %d 的状态信息不完整", pid)
	}
	return strconv.ParseUint(string(fields[19]), 10, 64)
}

func bootTimeAt(moment time.Time) time.Duration {
	var now unix.Timespec
	if err := unix.ClockGettime(unix.CLOCK_BOOTTIME, &now); err != nil {
		return 0
	}
	return time.Duration(now.Nano()) - time.Since(moment)
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

func resolveKernelUser() (int, int) {
	account, err := user.Lookup(kernelUserName)
	if err != nil {
		return -1, -1
	}
	uid, ok := parseKernelID(account.Uid)
	if !ok {
		return -1, -1
	}
	gid, ok := parseKernelID(account.Gid)
	if !ok {
		return -1, -1
	}
	return uid, gid
}

func applyKernelCredential(cmd *exec.Cmd) error {
	if kernelUID <= 0 || kernelGID <= 0 || uint64(kernelUID) > math.MaxUint32 || uint64(kernelGID) > math.MaxUint32 {
		return fmt.Errorf("内核专用账户 %s 不可用，请重新安装后台服务", kernelUserName)
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Credential:  &syscall.Credential{Uid: uint32(kernelUID), Gid: uint32(kernelGID)},
		AmbientCaps: []uintptr{unix.CAP_NET_ADMIN, unix.CAP_NET_RAW},
	}
	return nil
}
