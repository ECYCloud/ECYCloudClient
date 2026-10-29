//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const vendorDirName = "ECYCloud"

// 与 scripts/installer/ecycloud.iss 的 [Files]/[Run] 一致
const guiExeName = "ECYCloud.exe"

// 与 scripts/fetch-kernel.ps1 落盘的名字一致
const kernelExeName = "mihomo.exe"

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

// 与 Dart 侧 AppPaths.kernelCacheFile 必须一致；mihomo 固定写工作目录下的 cache.db
func kernelCachePath() string {
	return filepath.Join(runDir(), "cache.db")
}

func kernelCacheReady() bool {
	info, err := os.Stat(kernelCachePath())
	return err == nil && info.Size() > 0
}

// 快照被服务完全信任，必须落在已收紧的运行目录，不能放在 %ProgramData% 子目录根下
func snapshotPath() string {
	return filepath.Join(runDir(), "proxy-snapshot.json")
}

func serviceLogPath() string {
	return filepath.Join(dataDir(), "service.log")
}

func fatalLogPath() string {
	return filepath.Join(dataDir(), "service-fatal.log")
}

func kernelPath() string {
	return filepath.Join(installDir(), kernelExeName)
}
