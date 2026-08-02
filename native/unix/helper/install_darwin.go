//go:build darwin

package main

import (
	"fmt"
	"os"
	"os/exec"
)

// LaunchDaemon 由 root 常驻，GUI 每次连接都不再弹密码；
// 装包时装一次，之后升级客户端不需要重新授权。
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
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
`, daemonLabel, exe)

	uninstall()
	if err := os.WriteFile(daemonPlist, []byte(plist), 0o644); err != nil {
		return fmt.Errorf("写入 %s 失败: %w", daemonPlist, err)
	}
	if out, err := exec.Command("/bin/launchctl", "bootstrap", "system", daemonPlist).CombinedOutput(); err != nil {
		return fmt.Errorf("加载后台服务失败: %s", trimOutput(out, err))
	}
	return nil
}

func uninstall() error {
	// 未加载时 bootout 会报错，卸载流程不该因此中断
	exec.Command("/bin/launchctl", "bootout", "system/"+daemonLabel).Run()
	if err := os.Remove(daemonPlist); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("删除 %s 失败: %w", daemonPlist, err)
	}
	return nil
}
