//go:build windows

package main

import (
	"os"
	"path/filepath"
)

const vendorDirName = "ECYCloud"

// 与 scripts/installer/ecycloud.iss 的 [Files]/[Run] 一致：GUI 装在 {app}\ECYCloud.exe，
// 服务装在 {app}\service\ecycloud-service.exe，即 installDir() 的上一级
const guiExeName = "ECYCloud.exe"

// 安装器把 sing-box.exe 与 wintun.dll 放在与服务同一目录
func installDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(exe)
}

func guiExePath() string {
	return filepath.Join(filepath.Dir(installDir()), guiExeName)
}

func dataDir() string {
	return filepath.Join(os.Getenv("ProgramData"), vendorDirName)
}

// 内容含 Clash API 密钥，必须经 ensureRestrictedDir 收紧 DACL 后再使用
func runDir() string {
	return filepath.Join(dataDir(), "run")
}

func configPath() string {
	return filepath.Join(runDir(), "config.json")
}

// 与 Dart 侧 AppPaths.kernelCacheFile 必须一致：内核把远程规则集缓存写在这里，
// 文件存在即说明规则集已下载过，GUI 无权读取该目录只能由服务代查
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

func serviceLogPath() string {
	return filepath.Join(dataDir(), "service.log")
}

// 运行时致命错误的落点，见 redirectStderr
func fatalLogPath() string {
	return filepath.Join(dataDir(), "service-fatal.log")
}

func kernelPath() string {
	return filepath.Join(installDir(), "sing-box.exe")
}

func wintunPath() string {
	return filepath.Join(installDir(), "wintun.dll")
}
