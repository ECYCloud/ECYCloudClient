//go:build darwin || linux

package main

import (
	"os"
	"path/filepath"
	"runtime"
)

const vendorDirName = "ECYCloud"

// 与 Dart 侧 HelperClient.defaultSocketPath 必须一致
const socketPath = "/var/run/ecycloud/helper.sock"

// 安装脚本把内核与 helper 放在同一目录
func installDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "."
	}
	resolved, err := filepath.EvalSymlinks(exe)
	if err != nil {
		resolved = exe
	}
	return filepath.Dir(resolved)
}

// 与 Dart 侧 AppPaths.machineData 必须一致
func dataDir() string {
	if runtime.GOOS == "darwin" {
		return filepath.Join("/Library/Application Support", vendorDirName)
	}
	return filepath.Join("/var/lib", vendorDirName)
}

// verifyGUICaller 唯一认可的调用方，由安装包固定装在这里
func guiExePath() string {
	if runtime.GOOS == "darwin" {
		return "/Applications/ECYCloud.app/Contents/MacOS/ECYCloud"
	}
	return "/opt/ecycloud/ECYCloud"
}

// 内容含 Clash API 密钥，必须经 ensureRestrictedDir 收紧权限后再使用
func runDir() string {
	return filepath.Join(dataDir(), "run")
}

func configPath() string {
	return filepath.Join(runDir(), "config.json")
}

// 与 Dart 侧 AppPaths.kernelCacheFile 必须一致：内核把远程规则集缓存写在这里，
// 文件存在即说明规则集已下载过，GUI 无权读取该目录只能由 helper 代查
func kernelCachePath() string {
	return filepath.Join(runDir(), "cache.db")
}

func kernelCacheReady() bool {
	info, err := os.Stat(kernelCachePath())
	return err == nil && info.Size() > 0
}

func snapshotPath() string {
	return filepath.Join(dataDir(), "proxy-snapshot.json")
}

func helperLogPath() string {
	return filepath.Join(dataDir(), "helper.log")
}

func kernelPath() string {
	return filepath.Join(installDir(), "sing-box")
}

func updateDir() string {
	return filepath.Join(dataDir(), "update")
}
