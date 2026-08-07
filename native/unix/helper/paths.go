//go:build darwin || linux

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

const vendorDirName = "ECYCloud"

// 与 Dart 侧 HelperClient.defaultSocketPath 必须一致
const socketPath = "/var/run/ecycloud/helper.sock"

// 与 scripts/fetch-kernel.sh 落盘的名字一致
const kernelExeName = "mihomo"

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
// GUI 无权读取该目录只能由 helper 代查
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
	return filepath.Join(installDir(), kernelExeName)
}

func updateDir() string {
	return filepath.Join(dataDir(), "update")
}
