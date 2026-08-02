//go:build windows

package main

import (
	"archive/zip"
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

// GUI 只能给版本号，资产名、下载地址与校验值一律由服务自己从官方仓库解析：
// 这段代码跑在 SYSTEM 下、写的是安装目录，不能让调用方指定下载什么。
const (
	releaseAPI      = "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v%s"
	downloadPrefix  = "https://github.com/SagerNet/sing-box/releases/download/"
	maxArchiveSize  = 128 << 20
	upgradeTimeout  = 10 * time.Minute
	apiTimeout      = 20 * time.Second
	kernelBackupExt = ".bak"
)

// 发布包里需要落地的文件及其安装后的名字，与 scripts/fetch-kernel.ps1 的 singBox.files 一致
var kernelPayload = map[string]string{
	"sing-box.exe":  "sing-box.exe",
	"libcronet.dll": "libcronet.dll",
	"LICENSE":       "LICENSE.sing-box.txt",
}

var kernelVersionPattern = regexp.MustCompile(`^\d+(\.\d+){1,3}$`)

func updateDir() string {
	return filepath.Join(dataDir(), "update")
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
	if err := downloadVerified(url, archive, want); err != nil {
		return "", err
	}

	staged, err := extractKernel(archive, dir)
	if err != nil {
		return "", err
	}

	// 新内核先自证能跑：装到位之后才发现它起不来，用户就只剩重装客户端一条路
	installed := kernelVersionOf(staged["sing-box.exe"])
	if installed == "" {
		return "", fmt.Errorf("新内核无法运行，已放弃升级")
	}

	// 下载与校验期间内核一直在跑：网络受限时只有隧道通着才取得到 GitHub。
	// 到这一步才停，替换完由 GUI 决定是否重连
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

	wanted := fmt.Sprintf("sing-box-%s-windows-%s.zip", version, runtime.GOARCH)
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
func downloadVerified(url, path, want string) error {
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
	written, err := io.Copy(io.MultiWriter(file, digest), io.LimitReader(response.Body, maxArchiveSize+1))
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return fmt.Errorf("写入下载内容失败: %w", err)
	}
	if written > maxArchiveSize {
		return fmt.Errorf("发布包超过 %d MiB，拒绝安装", maxArchiveSize>>20)
	}

	if got := hex.EncodeToString(digest.Sum(nil)); !strings.EqualFold(got, want) {
		return fmt.Errorf("校验失败：期望 %s，实际 %s", want, got)
	}
	return nil
}

// 只取 kernelPayload 认识的文件，按安装后的名字落在 dir 下，返回目标名到暂存路径的映射
func extractKernel(archive, dir string) (map[string]string, error) {
	reader, err := zip.OpenReader(archive)
	if err != nil {
		return nil, fmt.Errorf("发布包无法解压: %w", err)
	}
	defer reader.Close()

	staged := make(map[string]string, len(kernelPayload))
	for _, entry := range reader.File {
		target, ok := kernelPayload[filepath.Base(entry.Name)]
		if !ok || entry.FileInfo().IsDir() || staged[target] != "" {
			continue
		}

		path := filepath.Join(dir, target)
		if err := extractOne(entry, path); err != nil {
			return nil, err
		}
		staged[target] = path
	}

	if staged["sing-box.exe"] == "" {
		return nil, fmt.Errorf("发布包中没有 sing-box.exe")
	}
	return staged, nil
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

// 旧文件先改名留底，任一步失败就把已换过的全部换回去：宁可留在旧版本，
// 也不能让安装目录停在半新半旧的状态
func installKernel(staged map[string]string) error {
	replaced := make([]string, 0, len(staged))

	for target, source := range staged {
		if err := replaceInstalled(filepath.Join(installDir(), target), source); err != nil {
			restoreInstalled(replaced)
			return err
		}
		replaced = append(replaced, target)
	}

	for _, target := range replaced {
		os.Remove(filepath.Join(installDir(), target+kernelBackupExt))
	}
	return nil
}

func replaceInstalled(path, source string) error {
	backup := path + kernelBackupExt
	os.Remove(backup)

	if _, err := os.Stat(path); err == nil {
		if err := os.Rename(path, backup); err != nil {
			return fmt.Errorf("移走旧的 %s 失败: %w", filepath.Base(path), err)
		}
	}

	// 不能用 os.Rename：安装目录与 ProgramData 可能不在同一个卷上
	if err := copyFile(source, path); err != nil {
		os.Rename(backup, path)
		return err
	}
	return nil
}

func restoreInstalled(replaced []string) {
	for _, target := range replaced {
		path := filepath.Join(installDir(), target)
		os.Remove(path)
		if err := os.Rename(path+kernelBackupExt, path); err != nil {
			logf("回滚 %s 失败: %v", target, err)
		}
	}
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
