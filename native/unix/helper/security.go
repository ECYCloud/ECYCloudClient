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

// 内核不与 helper 同权：Linux 上跑在受限用户下，macOS 上才是 root。
// 运行目录与配置都要归到这个身份，否则内核读不了配置、写不了 cache.db。
var kernelUID, kernelGID = resolveKernelUser()

// 目录里有 Clash API 密钥，只对内核身份开放；已存在时也要重设权限与属主，
// 避免沿用历史遗留的宽松模式
func ensureRestrictedDir(path string) error {
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

// 与 writeKernelFile 同一要求，只是内容来自文件而非字符串（geodata 有十几 MB，
// 不该先读进内存）。属主不归到内核身份，内核就打不开这些库
func copyKernelFile(source, path string) error {
	if err := copyFile(source, path); err != nil {
		return err
	}
	return os.Chown(path, kernelUID, kernelGID)
}

// kernel.start / kernel.upgrade 会让 helper 以特权执行调用方给的内容，只能放行安装
// 目录下那个官方 GUI；套接字权限管不到"哪个进程"，只能在应用层核对真实调用方的
// 可执行文件路径。两侧都解一遍软链，避免 /opt 或 /Applications 被软链接绕过。
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

// Unix 下 GUI 不是 helper 的子进程，等不到 SIGCHLD，只能按信号 0 探活
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
