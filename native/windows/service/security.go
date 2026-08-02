//go:build windows

package main

import (
	"fmt"
	"net"
	"os"
	"strings"

	"golang.org/x/sys/windows"
)

// SYSTEM 与管理员完全控制，交互登录用户可读写，其余主体无权访问
const pipeSDDL = "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)"

// 仅 SYSTEM 与管理员，阻止本地其它账户读取 Clash API 密钥
const runDirSDDL = "D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"

// 目录已存在时也要重写 DACL，否则会沿用历史遗留的宽松权限
func ensureRestrictedDir(path string) error {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return err
	}

	sd, err := windows.SecurityDescriptorFromString(runDirSDDL)
	if err != nil {
		return fmt.Errorf("解析目录 DACL 失败: %w", err)
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return fmt.Errorf("读取目录 DACL 失败: %w", err)
	}

	return windows.SetNamedSecurityInfo(
		path,
		windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
		nil, nil, dacl, nil,
	)
}

// 不能改用 WTSQueryUserToken 取控制台会话用户：那需要 SE_TCB_NAME，
// debug 模式下拿不到，也认不出远程桌面会话里的 GUI。
func clientUserSID(pid int) (string, error) {
	if pid <= 0 {
		return "", fmt.Errorf("请求缺少 GUI 进程 ID，无法定位用户配置单元")
	}

	handle, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		return "", fmt.Errorf("打开 GUI 进程 %d 失败: %w", pid, err)
	}
	defer windows.CloseHandle(handle)

	var token windows.Token
	if err := windows.OpenProcessToken(handle, windows.TOKEN_QUERY, &token); err != nil {
		return "", fmt.Errorf("读取 GUI 进程令牌失败: %w", err)
	}
	defer token.Close()

	user, err := token.GetTokenUser()
	if err != nil {
		return "", fmt.Errorf("读取用户令牌失败: %w", err)
	}
	return user.User.Sid.String(), nil
}

// 管道 DACL 对所有交互用户开放读写（同一账户下的其它进程无法用 ACL 区分），
// 请求体里的 PID 是调用方自己填的、不可信，只能取内核记录的真实连接进程
func pipeClientPID(conn net.Conn) (int, error) {
	handle, ok := conn.(interface{ Fd() uintptr })
	if !ok {
		return 0, fmt.Errorf("无法获取管道连接的底层句柄")
	}

	var pid uint32
	if err := windows.GetNamedPipeClientProcessId(windows.Handle(handle.Fd()), &pid); err != nil {
		return 0, fmt.Errorf("查询管道客户端进程失败: %w", err)
	}
	return int(pid), nil
}

// kernel.start / kernel.upgrade 会让 SYSTEM 执行调用方给的内容，只能放行安装目录下
// 那个官方 GUI；DACL 管不到"同账户下哪个进程"，只能在应用层核对真实调用方的可执行文件路径
func verifyGUICaller(pid int) error {
	handle, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		return fmt.Errorf("打开调用方进程失败: %w", err)
	}
	defer windows.CloseHandle(handle)

	buf := make([]uint16, windows.MAX_PATH)
	size := uint32(len(buf))
	if err := windows.QueryFullProcessImageName(handle, 0, &buf[0], &size); err != nil {
		return fmt.Errorf("查询调用方可执行文件失败: %w", err)
	}

	if actual := windows.UTF16ToString(buf[:size]); !strings.EqualFold(actual, guiExePath()) {
		return fmt.Errorf("拒绝来自非官方客户端的指令: %s", actual)
	}
	return nil
}

func watchProcess(pid int, onExit func()) error {
	if pid <= 0 {
		return fmt.Errorf("无效的进程 ID %d", pid)
	}

	handle, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(pid))
	if err != nil {
		return fmt.Errorf("打开进程 %d 失败: %w", pid, err)
	}

	go func() {
		defer windows.CloseHandle(handle)
		if _, err := windows.WaitForSingleObject(handle, windows.INFINITE); err != nil {
			return
		}
		onExit()
	}()
	return nil
}
