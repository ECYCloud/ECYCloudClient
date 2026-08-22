//go:build windows

package main

import (
	"fmt"
	"net"
	"os"
	"strings"

	"golang.org/x/sys/windows"
)

const pipeSDDL = "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)"

// 仅 SYSTEM/管理员，否则其它账户可读 Clash API 密钥
const runDirSDDL = "D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"

// 缺这道 DACL 等于允许替换特权二进制
const installDirSDDL = "D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FRFX;;;BU)"

// %ProgramData% 默认 ACL 下普通用户可建目录并获 WRITE_DAC，只重写 DACL 会被改回来
func ensureRestrictedDir(path string) error {
	if err := ensureOwnedDir(path); err != nil {
		return err
	}
	return applyDACL(path, runDirSDDL)
}

func ensureOwnedDir(path string) error {
	err := os.Mkdir(path, 0o700)
	if err == nil {
		return nil
	}
	if !os.IsExist(err) {
		return err
	}

	reparse, err := hasReparsePoint(path)
	if err != nil {
		return err
	}
	if reparse {
		return fmt.Errorf("目录 %s 是重解析点，拒绝使用", path)
	}

	trusted, err := ownedByAdmins(path)
	if err != nil {
		return err
	}
	if trusted {
		return nil
	}
	if err := takeOwnership(path); err != nil {
		return fmt.Errorf("目录 %s 的属主不可信且无法收归管理员: %w", path, err)
	}
	return nil
}

func hasReparsePoint(path string) (bool, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return false, err
	}
	attrs, err := windows.GetFileAttributes(name)
	if err != nil {
		return false, fmt.Errorf("读取 %s 的属性失败: %w", path, err)
	}
	return attrs&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0, nil
}

func ownedByAdmins(path string) (bool, error) {
	sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION)
	if err != nil {
		return false, fmt.Errorf("读取 %s 的属主失败: %w", path, err)
	}
	owner, _, err := sd.Owner()
	if err != nil {
		return false, fmt.Errorf("解析 %s 的属主失败: %w", path, err)
	}
	return owner.IsWellKnown(windows.WinLocalSystemSid) ||
		owner.IsWellKnown(windows.WinBuiltinAdministratorsSid), nil
}

// 收归 Administrators：该组在服务令牌里带 SE_GROUP_OWNER，不需要 SeRestorePrivilege
func takeOwnership(path string) error {
	owner, err := windows.CreateWellKnownSid(windows.WinBuiltinAdministratorsSid)
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(
		path,
		windows.SE_FILE_OBJECT,
		windows.OWNER_SECURITY_INFORMATION,
		owner, nil, nil, nil,
	)
}

// 目录已存在时也要重写 DACL，否则会沿用历史遗留的宽松权限
func applyDACL(path string, sddl string) error {
	sd, err := windows.SecurityDescriptorFromString(sddl)
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

// 不能改用 WTSQueryUserToken：需要 SE_TCB_NAME，debug 拿不到，也认不出远程桌面会话
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

// 请求体里的 PID 不可信，只能取管道对端的真实进程
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

// 管道 DACL 只能收到交互用户，必须再核对接官方 GUI 可执行文件路径
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
