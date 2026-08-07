//go:build darwin || linux

package main

import (
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
)

// GUI 只能给版本号，资产名、下载地址与校验值一律由 helper 自己从官方仓库解析：
// 这段代码跑在特权下、写的是安装目录，不能让调用方指定下载什么。
const (
	releaseAPI      = "https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/v%s"
	downloadPrefix  = "https://github.com/MetaCubeX/mihomo/releases/download/"
	maxArchiveSize  = 128 << 20
	upgradeTimeout  = 10 * time.Minute
	apiTimeout      = 20 * time.Second
	kernelBackupExt = ".bak"
	kernelExeMode   = 0o755
)

var kernelVersionPattern = regexp.MustCompile(`^\d+(\.\d+){1,3}$`)

// amd64 一律取 compatible（GOAMD64=v1）：官方不带后缀的 amd64 目标是 GOAMD64=v3，
// 在 Haswell 之前的 CPU 上会因非法指令崩溃。须与 scripts/kernel.lock.json 一致。
func kernelAssetTarget() string {
	if runtime.GOARCH == "amd64" {
		return runtime.GOOS + "-amd64-compatible"
	}
	return runtime.GOOS + "-" + runtime.GOARCH
}

func (s *server) setUpgradeProgress(stage string, percent int) {
	s.progress.mu.Lock()
	s.progress.stage = stage
	s.progress.percent = percent
	s.progress.mu.Unlock()
}

func (s *server) upgradeProgress() map[string]any {
	s.progress.mu.Lock()
	defer s.progress.mu.Unlock()
	return map[string]any{"stage": s.progress.stage, "percent": s.progress.percent}
}

// 返回实际安装到的版本。GUI 负责在成功后决定是否重连内核。
func (s *server) upgradeKernel(version string) (string, error) {
	if !kernelVersionPattern.MatchString(version) {
		return "", fmt.Errorf("版本号 %q 不合法", version)
	}
	if !s.upgrading.TryLock() {
		return "", fmt.Errorf("已有一个升级任务在进行中")
	}
	defer s.upgrading.Unlock()
	defer s.setUpgradeProgress("", 0)

	s.setUpgradeProgress("resolving", 0)
	name, url, want, err := resolveKernelAsset(version)
	if err != nil {
		return "", err
	}

	dir := updateDir()
	if err := ensureRestrictedDir(dir); err != nil {
		return "", fmt.Errorf("准备升级目录失败: %w", err)
	}
	defer os.RemoveAll(dir)

	archive := filepath.Join(dir, name)
	logf("开始下载内核 %s", url)
	if err := s.downloadVerified(url, archive, want); err != nil {
		return "", err
	}

	s.setUpgradeProgress("extracting", 0)
	staged, err := extractKernel(archive, dir)
	if err != nil {
		return "", err
	}

	// 新内核先自证能跑：装到位之后才发现它起不来，用户就只剩重装客户端一条路
	installed := kernelVersionOf(staged)
	if installed == "" {
		return "", fmt.Errorf("新内核无法运行，已放弃升级")
	}

	// 下载与校验期间内核一直在跑：网络受限时只有隧道通着才取得到 GitHub。
	// 到这一步才停，替换完由 GUI 决定是否重连
	s.setUpgradeProgress("installing", 0)
	s.kernel.stop()
	if err := installKernel(staged); err != nil {
		return "", err
	}

	logf("内核已升级：%s", installed)
	return version, nil
}

func resolveKernelAsset(version string) (name string, url string, sha256Hex string, err error) {
	client := &http.Client{Timeout: apiTimeout}
	request, err := http.NewRequest(http.MethodGet, fmt.Sprintf(releaseAPI, version), nil)
	if err != nil {
		return "", "", "", err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	// GitHub API 拒绝没有 User-Agent 的请求
	request.Header.Set("User-Agent", helperName+"/"+helperVersion)

	response, err := client.Do(request)
	if err != nil {
		return "", "", "", fmt.Errorf("查询发布信息失败: %w", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		return "", "", "", fmt.Errorf("查询发布信息失败: HTTP %d", response.StatusCode)
	}

	var release struct {
		Assets []struct {
			Name   string `json:"name"`
			URL    string `json:"browser_download_url"`
			Digest string `json:"digest"`
		} `json:"assets"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 4<<20)).Decode(&release); err != nil {
		return "", "", "", fmt.Errorf("解析发布信息失败: %w", err)
	}

	wanted := fmt.Sprintf("mihomo-%s-v%s.gz", kernelAssetTarget(), version)
	for _, asset := range release.Assets {
		if asset.Name != wanted {
			continue
		}
		digest, ok := strings.CutPrefix(asset.Digest, "sha256:")
		if !ok || len(digest) != 64 {
			return "", "", "", fmt.Errorf("上游未给出 %s 的 SHA-256，拒绝安装未经校验的内核", wanted)
		}
		if !strings.HasPrefix(asset.URL, downloadPrefix) {
			return "", "", "", fmt.Errorf("下载地址 %q 不在官方发布路径下", asset.URL)
		}
		return asset.Name, asset.URL, digest, nil
	}
	return "", "", "", fmt.Errorf("该版本没有提供 %s", wanted)
}

// 校验值来自 Releases API，与二进制同源：它挡的是传输损坏与镜像替换，
// 所以下载允许跟随 GitHub 自己的重定向（正文会重定向到 objects.githubusercontent.com）
func (s *server) downloadVerified(url, path, want string) error {
	client := &http.Client{Timeout: upgradeTimeout}
	response, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("下载内核失败: %w", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("下载内核失败: HTTP %d", response.StatusCode)
	}

	file, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("创建临时文件失败: %w", err)
	}

	digest := sha256.New()
	writer := io.MultiWriter(file, digest)
	reader := io.LimitReader(response.Body, maxArchiveSize+1)
	total := response.ContentLength
	s.setUpgradeProgress("downloading", 0)

	buf := make([]byte, 32<<10)
	var written int64
	var lastPercent int
	for {
		n, readErr := reader.Read(buf)
		if n > 0 {
			if _, err := writer.Write(buf[:n]); err != nil {
				file.Close()
				return fmt.Errorf("写入下载内容失败: %w", err)
			}
			written += int64(n)
			if total > 0 {
				percent := int(written * 100 / total)
				if percent > 100 {
					percent = 100
				}
				if percent != lastPercent {
					lastPercent = percent
					s.setUpgradeProgress("downloading", percent)
				}
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			file.Close()
			return fmt.Errorf("写入下载内容失败: %w", readErr)
		}
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("写入下载内容失败: %w", err)
	}
	if written > maxArchiveSize {
		return fmt.Errorf("发布包超过 %d MiB，拒绝安装", maxArchiveSize>>20)
	}

	s.setUpgradeProgress("verifying", 0)
	if got := hex.EncodeToString(digest.Sum(nil)); !strings.EqualFold(got, want) {
		return fmt.Errorf("校验失败：期望 %s，实际 %s", want, got)
	}
	return nil
}

// 官方 Unix 产物是单个 gzip 压缩的可执行文件，不是 tar 包：直接解到 dir 下并返回其路径
func extractKernel(archive, dir string) (string, error) {
	file, err := os.Open(archive)
	if err != nil {
		return "", fmt.Errorf("发布包无法读取: %w", err)
	}
	defer file.Close()

	gz, err := gzip.NewReader(file)
	if err != nil {
		return "", fmt.Errorf("发布包无法解压: %w", err)
	}
	defer gz.Close()

	path := filepath.Join(dir, kernelExeName)
	if err := extractOne(gz, path, kernelExeMode); err != nil {
		return "", err
	}
	return path, nil
}

func extractOne(source io.Reader, path string, mode os.FileMode) error {
	if mode == 0 {
		mode = 0o600
	}

	file, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return fmt.Errorf("展开 %s 失败: %w", filepath.Base(path), err)
	}

	_, err = io.Copy(file, io.LimitReader(source, maxArchiveSize))
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return fmt.Errorf("展开 %s 失败: %w", filepath.Base(path), err)
	}
	// OpenFile 的权限会被 umask 削掉，内核少了执行位就跑不起来
	return os.Chmod(path, mode)
}

// 旧文件先改名留底，替换失败就换回去：宁可留在旧版本，也不能让安装目录停在坏状态
func installKernel(source string) error {
	path := kernelPath()
	backup := path + kernelBackupExt
	os.Remove(backup)

	if _, err := os.Stat(path); err == nil {
		if err := os.Rename(path, backup); err != nil {
			return fmt.Errorf("移走旧的 %s 失败: %w", kernelExeName, err)
		}
	}

	// 不能用 os.Rename：安装目录与升级目录可能不在同一个文件系统上
	if err := copyFile(source, path); err != nil {
		os.Remove(path)
		if restoreErr := os.Rename(backup, path); restoreErr != nil {
			logf("回滚 %s 失败: %v", kernelExeName, restoreErr)
		}
		return err
	}

	os.Remove(backup)
	return nil
}

func copyFile(source, path string) error {
	info, err := os.Stat(source)
	if err != nil {
		return err
	}

	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, info.Mode().Perm())
	if err != nil {
		return fmt.Errorf("写入 %s 失败: %w", filepath.Base(path), err)
	}

	_, err = io.Copy(out, in)
	if closeErr := out.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return fmt.Errorf("写入 %s 失败: %w", filepath.Base(path), err)
	}
	return os.Chmod(path, info.Mode().Perm())
}
