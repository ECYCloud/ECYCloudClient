//go:build darwin || linux

package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	kernelLogLines = 800

	// 不得为容纳 geox-url 现下载而抬高：缺 geodata 时内核每文件 90 秒同步下载
	kernelCheckTimout = 30 * time.Second

	kernelStopTimeout = 5 * time.Second
)

// mihomo MMDB() 认 Country.mmdb / geoip.db / geoip.metadb，GeoSite 认 GeoSite.dat
var geoDataFileNames = []string{"geoip.metadb", "GeoSite.dat"}

func prepareRunDir() error {
	if err := ensureRestrictedDir(runDir()); err != nil {
		return fmt.Errorf("准备运行目录失败: %w", err)
	}
	seedGeoData()
	return nil
}

// 已存在的不覆盖：内核 geo-auto-update 刷新过的那份比包内的新
func seedGeoData() {
	for _, name := range geoDataFileNames {
		target := filepath.Join(runDir(), name)
		if _, err := os.Stat(target); err == nil {
			continue
		}
		if err := copyKernelFile(filepath.Join(installDir(), name), target); err != nil {
			logf("播种 %s 失败，内核将自行下载: %v", name, err)
		}
	}
}

type kernelManager struct {
	mu       sync.Mutex
	cmd      *exec.Cmd
	pid      int
	running  bool
	stopping bool
	exitCode int
	lastErr  string
	logs     *logBuffer
	done     chan struct{}
}

func newKernelManager() *kernelManager {
	return &kernelManager{logs: newLogBuffer(kernelLogLines), exitCode: -1}
}

// 只落盘，不碰进程；热载由 GUI 对控制面 PUT /configs
func (k *kernelManager) write(config string) error {
	if err := prepareRunDir(); err != nil {
		return err
	}
	if err := writeKernelFile(configPath(), config); err != nil {
		return fmt.Errorf("写入配置失败: %w", err)
	}
	return nil
}

const maxRunFileBytes = 8 << 20

// run 目录 0700 / 内核用户，GUI 只能由 helper 代读
func (k *kernelManager) read(rel string) (string, error) {
	path, err := resolveRunFile(rel)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", fmt.Errorf("文件不存在")
		}
		return "", err
	}
	if info.IsDir() {
		return "", fmt.Errorf("不能读取目录")
	}
	if info.Size() > maxRunFileBytes {
		return "", fmt.Errorf("文件过大（超过 %d MiB）", maxRunFileBytes>>20)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("读取失败: %w", err)
	}
	return string(data), nil
}

func (k *kernelManager) start(config string) error {
	if _, err := os.Stat(kernelPath()); err != nil {
		return fmt.Errorf("内核程序缺失: %s", kernelPath())
	}
	if err := k.write(config); err != nil {
		return err
	}

	k.stop()

	k.mu.Lock()
	defer k.mu.Unlock()

	cmd := exec.Command(kernelPath(), "-d", runDir(), "-f", configPath())
	cmd.Dir = runDir()
	applyKernelCredential(cmd)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("接管内核输出失败: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("接管内核错误输出失败: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("启动内核失败: %w", err)
	}

	k.cmd = cmd
	k.pid = cmd.Process.Pid
	k.running = true
	k.stopping = false
	k.exitCode = -1
	k.lastErr = ""
	k.done = make(chan struct{})

	var pumps sync.WaitGroup
	pumps.Add(2)
	go k.pump(stdout, &pumps)
	go k.pump(stderr, &pumps)

	done := k.done
	go func() {
		defer guard("等待内核退出")
		defer close(done)

		pumps.Wait()
		err := cmd.Wait()

		k.mu.Lock()
		defer k.mu.Unlock()
		k.running = false
		k.exitCode = cmd.ProcessState.ExitCode()
		if err != nil && !k.stopping {
			k.lastErr = err.Error()
		}
	}()

	return nil
}

func (k *kernelManager) pump(r io.ReadCloser, wg *sync.WaitGroup) {
	defer wg.Done()
	defer guard("转存内核输出")
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		k.logs.append(scanner.Text())
	}
}

// SIGINT 走 mihomo 自己的退出流程，超时不退才 SIGKILL
func (k *kernelManager) stop() {
	k.mu.Lock()
	if !k.running || k.cmd == nil || k.cmd.Process == nil {
		k.mu.Unlock()
		return
	}
	k.stopping = true
	process := k.cmd.Process
	done := k.done
	k.mu.Unlock()

	if err := process.Signal(syscall.SIGINT); err != nil {
		process.Kill()
	}

	select {
	case <-done:
		return
	case <-time.After(kernelStopTimeout):
	}

	logf("内核在 %s 内没有响应 SIGINT，改为强制结束", kernelStopTimeout)
	process.Kill()
	select {
	case <-done:
	case <-time.After(kernelStopTimeout):
		logf("内核进程 %d 仍未回收", process.Pid)
	}
}

type kernelStatus struct {
	Running  bool     `json:"running"`
	PID      int      `json:"pid,omitempty"`
	ExitCode *int     `json:"exit_code,omitempty"`
	Error    string   `json:"error,omitempty"`
	LogLines []string `json:"log_lines"`
	LogCursr int      `json:"log_cursor"`
}

func (k *kernelManager) status(cursor int) kernelStatus {
	lines, next := k.logs.since(cursor)

	k.mu.Lock()
	defer k.mu.Unlock()

	status := kernelStatus{
		Running:  k.running,
		Error:    k.lastErr,
		LogLines: lines,
		LogCursr: next,
	}
	if k.running {
		status.PID = k.pid
	} else if k.exitCode >= 0 {
		code := k.exitCode
		status.ExitCode = &code
	}
	return status
}

func (k *kernelManager) check(config string) error {
	if err := prepareRunDir(); err != nil {
		return err
	}

	path := filepath.Join(runDir(), "config.check.json")
	if err := writeKernelFile(path, config); err != nil {
		return fmt.Errorf("写入待校验配置失败: %w", err)
	}
	defer os.Remove(path)

	ctx, cancel := context.WithTimeout(context.Background(), kernelCheckTimout)
	defer cancel()

	cmd := exec.CommandContext(ctx, kernelPath(), "-t", "-f", path, "-d", runDir())
	out, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	if message := kernelCheckFailure(string(out)); message != "" {
		return fmt.Errorf("%s", message)
	}
	return err
}

// mihomo 校验失败时真正原因在最后一条 level=error，末行只是 “test failed”
func kernelCheckFailure(out string) string {
	reason := ""
	for _, line := range strings.Split(out, "\n") {
		level, message, ok := splitKernelLogLine(line)
		if ok && message != "" && (level == "error" || level == "fatal") {
			reason = message
		}
	}
	if reason != "" {
		return reason
	}
	return strings.TrimSpace(out)
}

// 内核日志是 logrus 的 key=value 文本：time="..." level=error msg="..."
func splitKernelLogLine(line string) (level string, message string, ok bool) {
	level = logfmtValue(line, "level=")
	if level == "" {
		return "", "", false
	}
	return level, logfmtValue(line, "msg="), true
}

func logfmtValue(line string, key string) string {
	index := strings.Index(line, key)
	if index < 0 {
		return ""
	}
	rest := line[index+len(key):]
	if !strings.HasPrefix(rest, `"`) {
		if end := strings.IndexByte(rest, ' '); end >= 0 {
			return rest[:end]
		}
		return rest
	}
	if value, err := strconv.Unquote(rest[:quotedEnd(rest)]); err == nil {
		return value
	}
	return ""
}

func quotedEnd(rest string) int {
	for i := 1; i < len(rest); i++ {
		switch rest[i] {
		case '\\':
			i++
		case '"':
			return i + 1
		}
	}
	return len(rest)
}

func (k *kernelManager) kernelVersion() string {
	return kernelVersionOf(kernelPath())
}

func kernelVersionOf(exe string) string {
	out, err := exec.Command(exe, "-v").Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			return line
		}
	}
	return ""
}
