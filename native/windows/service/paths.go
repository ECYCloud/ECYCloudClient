//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const vendorDirName = "ECYCloud"

// 与 scripts/installer/ecycloud.iss 的 [Files]/[Run] 一致：GUI 装在 {app}\ECYCloud.exe，
// 服务装在 {app}\service\ecycloud-service.exe，即 installDir() 的上一级
const guiExeName = "ECYCloud.exe"

// 与 scripts/fetch-kernel.ps1 落盘的名字一致
const kernelExeName = "mihomo.exe"

// 安装器把 mihomo.exe 放在与服务同一目录
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

// 只允许读 run 目录下的相对路径；拒绝绝对路径与 `..`。
func resolveRunFile(rel string) (string, error) {
	rel = strings.TrimSpace(rel)
	rel = strings.ReplaceAll(rel, `\`, `/`)
	rel = strings.TrimPrefix(rel, "./")
	rel = filepath.Clean(filepath.FromSlash(rel))
	if rel == "." || rel == "" || strings.HasPrefix(rel, "..") || filepath.IsAbs(rel) {
		return "", fmt.Errorf("非法路径")
	}
	base, err := filepath.Abs(runDir())
	if err != nil {
		return "", err
	}
	full, err := filepath.Abs(filepath.Join(base, rel))
	if err != nil {
		return "", err
	}
	sep := string(os.PathSeparator)
	if full != base && !strings.HasPrefix(full, base+sep) {
		return "", fmt.Errorf("非法路径")
	}
	return full, nil
}

// 与 Dart 侧 AppPaths.kernelCacheFile 必须一致：内核把选中项与规则缓存写在这里
// （mihomo 固定取工作目录下的 cache.db），文件存在即说明已完整跑过一轮，
// GUI 无权读取该目录只能由服务代查
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
	return filepath.Join(installDir(), kernelExeName)
}
