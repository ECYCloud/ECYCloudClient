//go:build windows

package main

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// GUI 只能给版本号；资产名、地址与校验值由本进程从官方仓库解析，不能让调用方指定
const (
	releaseAPI      = "https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/v%s"
	downloadPrefix  = "https://github.com/MetaCubeX/mihomo/releases/download/"
	maxArchiveSize  = 128 << 20
	upgradeTimeout  = 10 * time.Minute
	apiTimeout      = 20 * time.Second
	kernelBackupExt = ".bak"
)

var kernelVersionPattern = regexp.MustCompile(`^\d+(\.\d+){1,3}$`)

// amd64 必须取 compatible（GOAMD64=v1），须与 scripts/kernel.lock.json 一致
func kernelAssetTarget() string {
	if runtime.GOARCH == "amd64" {
		return "windows-amd64-compatible"
	}
	return "windows-" + runtime.GOARCH
}

func updateDir() string {
	return filepath.Join(dataDir(), "update")
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

func (s *server) upgradeKernel(version string, proxyPort int) (string, error) {
	if !kernelVersionPattern.MatchString(version) {
		return "", fmt.Errorf("版本号 %q 不合法", version)
	}
	if !s.upgrading.TryLock() {
		return "", fmt.Errorf("已有一个升级任务在进行中")
	}
	defer s.upgrading.Unlock()
	defer s.setUpgradeProgress("", 0)

	s.setUpgradeProgress("resolving", 0)
	name, url, want, err := resolveKernelAsset(version, proxyPort)
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
	if err := s.downloadVerified(url, archive, want, proxyPort); err != nil {
		return "", err
	}

	s.setUpgradeProgress("extracting", 0)
	staged, err := extractKernel(archive, dir)
	if err != nil {
		return "", err
	}

	installed := kernelVersionOf(staged)
	if installed == "" {
		return "", fmt.Errorf("新内核无法运行，已放弃升级")
	}

	// 下载走本地 mixed 出网，内核必须撑到校验通过后才停
	s.setUpgradeProgress("installing", 0)
	s.kernel.stop()
	if err := installKernel(staged); err != nil {
		return "", err
	}

	logf("内核已升级：%s", installed)
	return version, nil
}

func githubHTTPClient(timeout time.Duration, proxyPort int) (*http.Client, error) {
	base, ok := http.DefaultTransport.(*http.Transport)
	if !ok {
		return nil, fmt.Errorf("无法配置 HTTP 传输")
	}
	transport := base.Clone()
	if proxyPort != 0 {
		if proxyPort <= 1024 || proxyPort > 65535 {
			return nil, fmt.Errorf("非法代理端口 %d", proxyPort)
		}
		transport.Proxy = http.ProxyURL(&url.URL{
			Scheme: "http",
			Host:   net.JoinHostPort("127.0.0.1", strconv.Itoa(proxyPort)),
		})
	}
	return &http.Client{Timeout: timeout, Transport: transport}, nil
}

func resolveKernelAsset(version string, proxyPort int) (name string, url string, sha256Hex string, err error) {
	client, err := githubHTTPClient(apiTimeout, proxyPort)
	if err != nil {
		return "", "", "", err
	}
	request, err := http.NewRequest(http.MethodGet, fmt.Sprintf(releaseAPI, version), nil)
	if err != nil {
		return "", "", "", err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	// GitHub API 拒绝没有 User-Agent 的请求
	request.Header.Set("User-Agent", serviceName+"/"+serviceVersion)

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

	wanted := fmt.Sprintf("mihomo-%s-v%s.zip", kernelAssetTarget(), version)
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

// digest 来自 Releases API，下载可跟随 GitHub 重定向
func (s *server) downloadVerified(fileURL, path, want string, proxyPort int) error {
	client, err := githubHTTPClient(upgradeTimeout, proxyPort)
	if err != nil {
		return err
	}
	response, err := client.Get(fileURL)
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

func extractKernel(archive, dir string) (string, error) {
	reader, err := zip.OpenReader(archive)
	if err != nil {
		return "", fmt.Errorf("发布包无法解压: %w", err)
	}
	defer reader.Close()

	wanted := fmt.Sprintf("mihomo-%s.exe", kernelAssetTarget())
	for _, entry := range reader.File {
		if entry.FileInfo().IsDir() || filepath.Base(entry.Name) != wanted {
			continue
		}

		path := filepath.Join(dir, kernelExeName)
		if err := extractOne(entry, path); err != nil {
			return "", err
		}
		return path, nil
	}
	return "", fmt.Errorf("发布包中没有 %s", wanted)
}

func extractOne(entry *zip.File, path string) error {
	source, err := entry.Open()
	if err != nil {
		return fmt.Errorf("读取发布包内 %s 失败: %w", entry.Name, err)
	}
	defer source.Close()

	file, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
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
	return nil
}

func installKernel(source string) error {
	path := kernelPath()
	backup := path + kernelBackupExt
	os.Remove(backup)

	if _, err := os.Stat(path); err == nil {
		if err := os.Rename(path, backup); err != nil {
			return fmt.Errorf("移走旧的 %s 失败: %w", kernelExeName, err)
		}
	}

	// 不能用 os.Rename：安装目录与 ProgramData 可能不在同一个卷上
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
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
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
	return nil
}
