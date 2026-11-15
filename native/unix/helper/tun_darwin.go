//go:build darwin

package main

import (
	"fmt"
	"os"
	"os/exec"
)

// utun 由系统内建，只需 helper 是 root
func ensureTunReady() (bool, string) {
	if _, err := os.Stat(kernelPath()); err != nil {
		return false, fmt.Sprintf("内核程序缺失: %s", kernelPath())
	}
	if os.Geteuid() != 0 {
		return false, "后台服务未以管理员身份运行，请重新运行安装包"
	}
	return true, ""
}

// utun 只认 root，macOS 也没有 capability 可降权
func resolveKernelUser() (int, int) { return 0, 0 }

func applyKernelCredential(_ *exec.Cmd) error { return nil }
