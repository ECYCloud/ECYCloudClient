//go:build linux

package main

import (
	"fmt"
	"os"
)

const tunDevice = "/dev/net/tun"

// 容器与部分精简发行版默认不带 tun 模块，内核起来后才报错就来不及给提示了
func ensureTunReady() (bool, string) {
	if _, err := os.Stat(kernelPath()); err != nil {
		return false, fmt.Sprintf("内核程序缺失: %s", kernelPath())
	}
	if _, err := os.Stat(tunDevice); err != nil {
		return false, fmt.Sprintf("系统缺少 %s，请执行 sudo modprobe tun 后重试", tunDevice)
	}
	if os.Geteuid() != 0 {
		return false, "后台服务未以 root 身份运行，请检查 ecycloud-helper.service"
	}
	return true, ""
}
