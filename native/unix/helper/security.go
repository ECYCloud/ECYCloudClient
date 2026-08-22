//go:build darwin || linux

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

const clientPollInterval = time.Second

// Linux 上内核跑受限用户，macOS 上才是 root；运行目录须归这个身份
var kernelUID, kernelGID = resolveKernelUser()

// 含 Clash API 密钥。软链接一律拒绝：/Library/Application Support 对 admin 可写
func ensureRestrictedDir(path string) error {
	if info, err := os.Lstat(path); err == nil && info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("目录 %s 是软链接，拒绝使用", path)
	}
	// MkdirAll 会把 0700 一路盖到上级，受限用户穿不过就打不开 run/
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(path, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(path, 0o700); err != nil {
		return err
	}
	return os.Chown(path, kernelUID, kernelGID)
}

func writeKernelFile(path string, content string) error {
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		return err
	}
	return os.Chown(path, kernelUID, kernelGID)
}

// 属主不归到内核身份，内核就打不开这些库
func copyKernelFile(source, path string) error {
	if err := copyFile(source, path); err != nil {
		return err
	}
	return os.Chown(path, kernelUID, kernelGID)
}

// 套接字权限管不到哪个进程；两侧都解软链，避免 /opt 或 /Applications 被绕过
func verifyGUICaller(pid int) error {
	actual, err := processExePath(pid)
	if err != nil {
		return err
	}
	if realPath(actual) != realPath(guiExePath()) {
		return fmt.Errorf("拒绝来自非官方客户端的指令: %s", actual)
	}
	return nil
}

func realPath(path string) string {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}
	return path
}

// GUI 不是 helper 的子进程，等不到 SIGCHLD，只能按信号 0 探活
func watchProcess(pid int, onExit func()) error {
	if pid <= 0 {
		return fmt.Errorf("无效的进程 ID %d", pid)
	}
	if err := syscall.Kill(pid, 0); err != nil {
		return fmt.Errorf("进程 %d 不可达: %w", pid, err)
	}

	go func() {
		defer guard("监听 GUI 进程")
		for {
			time.Sleep(clientPollInterval)
			if err := syscall.Kill(pid, 0); err != nil && err != syscall.EPERM {
				onExit()
				return
			}
		}
	}()
	return nil
}
