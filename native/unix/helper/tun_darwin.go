//go:build darwin

package main

import (
	"fmt"
	"os"
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
