//go:build darwin || linux

package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

const clientPollInterval = time.Second

// Linux 上内核跑受限用户，macOS 上才是 root；运行目录须归这个身份
var kernelUID, kernelGID = resolveKernelUser()

func ensureRestrictedDir(path string) error {
	if err := ensureDataDir(); err != nil {
		return err
	}
	uid, gid := 0, 0
	if path == runRoot() || path == runDir() {
		uid, gid = kernelUID, kernelGID
	}
	return ensureOwnedDir(path, uid, gid, 0o700)
}

func ensureDataDir() error {
	return ensureOwnedDir(dataDir(), 0, 0, 0o755)
}

func ensureOwnedDir(path string, uid, gid int, mode os.FileMode) error {
	if uid < 0 || gid < 0 {
		return fmt.Errorf("内核专用账户不可用，请重新安装后台服务")
	}
	if err := os.Mkdir(path, mode); err != nil && !os.IsExist(err) {
		return err
	}
	dir, err := os.OpenFile(path, os.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return err
	}
	defer dir.Close()
	info, err := dir.Stat()
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !info.IsDir() || !ok || (stat.Uid != 0 && stat.Uid != uint32(uid)) {
		return fmt.Errorf("目录 %s 的类型或属主不可信，拒绝使用", path)
	}
	if err := dir.Chmod(mode); err != nil {
		return err
	}
	return dir.Chown(uid, gid)
}

func writeKernelFile(path string, content io.Reader) error {
	root, err := os.OpenRoot(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer root.Close()
	name := filepath.Base(path)
	if info, err := root.Lstat(name); err == nil {
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !info.Mode().IsRegular() || !ok || stat.Nlink != 1 {
			return fmt.Errorf("文件 %s 的类型或链接数不可信", path)
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	// 写完整再改名顶替：直接写目标，中途被杀留下的半截文件会被当成已有文件沿用
	temp := name + ".tmp"
	if err := root.Remove(temp); err != nil && !os.IsNotExist(err) {
		return err
	}
	file, err := root.OpenFile(temp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer file.Close()
	if _, err := io.Copy(file, content); err != nil {
		return err
	}
	if err := file.Chown(kernelUID, kernelGID); err != nil {
		return err
	}
	return root.Rename(temp, name)
}

// 属主不归到内核身份，内核就打不开这些库
func copyKernelFile(source, path string) error {
	content, err := os.Open(source)
	if err != nil {
		return err
	}
	defer content.Close()
	return writeKernelFile(path, content)
}

// 套接字权限管不到哪个进程；两侧都解软链，避免 /opt 或 /Applications 被绕过
func verifyGUICaller(actual string) error {
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
