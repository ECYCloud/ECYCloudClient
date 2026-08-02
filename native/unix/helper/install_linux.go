//go:build linux

package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/user"
)

const unitName = "ecycloud-helper.service"
const unitPath = "/etc/systemd/system/" + unitName

func install() error {
	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("定位自身可执行文件失败: %w", err)
	}
	if err := ensureKernelUser(); err != nil {
		return err
	}

	unit := fmt.Sprintf(`[Unit]
Description=ECY Cloud 网络服务
After=network.target

[Service]
Type=simple
ExecStart=%s run
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
`, exe)

	if err := os.WriteFile(unitPath, []byte(unit), 0o644); err != nil {
		return fmt.Errorf("写入 %s 失败: %w", unitPath, err)
	}
	if err := systemctl("daemon-reload"); err != nil {
		return err
	}
	return systemctl("enable", "--now", unitName)
}

func uninstall() error {
	// 未启用时 disable 会报错，卸载流程不该因此中断
	exec.Command("systemctl", "disable", "--now", unitName).Run()
	if err := os.Remove(unitPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("删除 %s 失败: %w", unitPath, err)
	}
	return systemctl("daemon-reload")
}

// 内核降权跑在这个账户下，它不需要登录，也不需要家目录
func ensureKernelUser() error {
	if _, err := user.Lookup(kernelUserName); err == nil {
		return nil
	}

	cmd := exec.Command("useradd", "--system", "--no-create-home", "--shell", "/usr/sbin/nologin", kernelUserName)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("创建系统用户 %s 失败: %s", kernelUserName, trimOutput(out, err))
	}
	return nil
}

func systemctl(args ...string) error {
	if out, err := exec.Command("systemctl", args...).CombinedOutput(); err != nil {
		return fmt.Errorf("systemctl %v 失败: %s", args, trimOutput(out, err))
	}
	return nil
}
