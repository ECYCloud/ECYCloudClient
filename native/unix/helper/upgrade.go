//go:build darwin || linux

package main

import (
	"compress/gzip"
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
	kernelExeMode   = 0o755
)

var kernelVersionPattern = regexp.MustCompile(`^\d+(\.\d+){1,3}$`)

var installedVersionPattern = regexp.MustCompile(`\bv?(\d+(?:\.\d+){1,3})\b`)

// 从 mihomo -v 首行（如 "Mihomo Meta v1.19.33 darwin arm64 ..."）取版本号
func installedKernelVersion() string {
	match := installedVersionPattern.FindStringSubmatch(kernelVersionOf(kernelPath()))
	if match == nil {
		return ""
	}
	return match[1]
}

func compareKernelVersion(a, b string) int {
	left, right := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < 4; i++ {
		var x, y int
		if i < len(left) {
			x, _ = strconv.Atoi(left[i])
		}
		if i < len(right) {
			y, _ = strconv.Atoi(right[i])
		}
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	return 0
}

// amd64 必须取 compatible（GOAMD64=v1），须与 scripts/kernel.lock.json 一致
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

func (s *server) upgradeKernel(version string, proxyPort int) (string, error) {
	if !kernelVersionPattern.MatchString(version) {
		return "", fmt.Errorf("版本号 %q 不合法", version)
	}
	// 只许升级或重装同版本：注入官方 GUI 的调用方不能把以特权身份运行的内核换回旧版；读不出当前版本时放行，保留修复入口
	if current := installedKernelVersion(); current != "" && compareKernelVersion(version, current) < 0 {
		return "", fmt.Errorf("不能把内核降级到 %s（当前 %s）", version, current)
	}
	if !s.upgrading.TryLock() {
		return "", fmt.Errorf("已有一个升级任务在进行中")
	}
	defer s.upgrading.Unlock()
	defer s.setUpgradeProgress("", 0)

	if _, err := os.Stat(kernelPath() + kernelBackupExt); err == nil {
		return "", fmt.Errorf("存在尚未提交的旧内核备份，拒绝覆盖升级")
	} else if !os.IsNotExist(err) {
		return "", fmt.Errorf("检查旧内核备份失败: %w", err)
	}

	s.setUpgradeProgress("resolving", 0)
	name, url, want, err := resolveKernelAsset(version, proxyPort)
	if err != nil {
		return "", err
	}

	dir := updateDir()
	if err := ensureDataDir(); err != nil {
		return "", err
	}
	// 旧版暂存目录归内核用户；废弃其中内容后重建，不能接管后继续执行。
	if err := os.RemoveAll(dir); err != nil {
		return "", fmt.Errorf("清理升级目录失败: %w", err)
	}
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
	if err := s.kernel.stop(); err != nil {
		return "", fmt.Errorf("停止旧内核失败，已放弃升级: %w", err)
	}
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
		if !officialDownload(asset.URL) {
			return "", "", "", fmt.Errorf("下载地址 %q 不在官方发布路径下", asset.URL)
		}
		return asset.Name, asset.URL, digest, nil
	}
	return "", "", "", fmt.Errorf("该版本没有提供 %s", wanted)
}

// 只比较前缀会放过 releases/download/../../ 之类解析后落到别的仓库的地址
func officialDownload(raw string) bool {
	parsed, err := url.Parse(raw)
	if err != nil || !strings.HasPrefix(raw, downloadPrefix) || parsed.User != nil || parsed.Port() != "" {
		return false
	}
	for _, segment := range strings.Split(parsed.Path, "/") {
		if segment == "." || segment == ".." {
			return false
		}
	}
	return true
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

// 官方 Unix 产物是单个 gzip，不是 tar 包
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

func installKernel(source string) error {
	path := kernelPath()
	backup := path + kernelBackupExt
	staged := path + ".new"
	defer os.Remove(staged)

	// 升级目录可能在别的文件系统上，先拷进安装目录再改名顶替：
	// 直接往内核路径上写，中途被杀会留下半截内核，校验与再次升级都过不去
	if err := copyFile(source, staged); err != nil {
		return err
	}
	if info, err := os.Lstat(path); err == nil {
		if !info.Mode().IsRegular() {
			return fmt.Errorf("现有内核不是普通文件，拒绝替换")
		}
		if err := os.Link(path, backup); err != nil {
			return fmt.Errorf("备份旧的 %s 失败: %w", kernelExeName, err)
		}
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("检查现有内核失败: %w", err)
	}
	if err := os.Rename(staged, path); err != nil {
		os.Remove(backup)
		return fmt.Errorf("替换 %s 失败: %w", kernelExeName, err)
	}
	return nil
}

func commitKernelUpgrade() error {
	backup := kernelPath() + kernelBackupExt
	if err := os.Remove(backup); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("清理旧内核备份失败: %w", err)
	}
	return nil
}

func rollbackKernelUpgrade() error {
	path := kernelPath()
	backup := path + kernelBackupExt
	info, err := os.Lstat(backup)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("检查旧内核备份失败: %w", err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("旧内核备份不是普通文件，拒绝回滚")
	}
	if info, err := os.Lstat(path); err == nil {
		if !info.Mode().IsRegular() {
			return fmt.Errorf("候选内核不是普通文件，拒绝回滚")
		}
		if err := os.Remove(path); err != nil {
			return fmt.Errorf("删除候选内核失败: %w", err)
		}
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("检查候选内核失败: %w", err)
	}
	if err := os.Rename(backup, path); err != nil {
		return fmt.Errorf("恢复旧内核失败: %w", err)
	}
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
