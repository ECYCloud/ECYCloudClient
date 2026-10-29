//go:build darwin

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"syscall"
)

// LaunchDaemon 由 root 常驻，装一次后 GUI 不再弹密码
const (
	daemonLabel = "com.ecycloud.helper"
	daemonPlist = "/Library/LaunchDaemons/" + daemonLabel + ".plist"
)

func install() error {
	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("定位自身可执行文件失败: %w", err)
	}

	plist := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>%s</string>
	<key>ProgramArguments</key>
	<array>
		<string>%s</string>
		<string>run</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>AbandonProcessGroup</key>
	<false/>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
`, daemonLabel, exe)

	if err := uninstall(); err != nil {
		return err
	}
	if err := os.WriteFile(daemonPlist, []byte(plist), 0o644); err != nil {
		return fmt.Errorf("写入 %s 失败: %w", daemonPlist, err)
	}
	if out, err := exec.Command("/bin/launchctl", "bootstrap", "system", daemonPlist).CombinedOutput(); err != nil {
		return fmt.Errorf("加载后台服务失败: %s", trimOutput(out, err))
	}
	return nil
}

func uninstall() error {
	if out, err := exec.Command("/bin/launchctl", "bootout", "system/"+daemonLabel).CombinedOutput(); err != nil {
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) || exitErr.ExitCode() != int(syscall.ESRCH) {
			return fmt.Errorf("停止后台服务失败: %s", trimOutput(out, err))
		}
	}
	if err := os.Remove(daemonPlist); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("删除 %s 失败: %w", daemonPlist, err)
	}
	return nil
}
