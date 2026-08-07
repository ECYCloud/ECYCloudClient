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

	// geodata 由 seedGeoData 播种到位后，校验是纯本地动作：实测面板那份配置
	// （25 个 rule-providers + 3 条 geo 规则）耗时 0.4 秒左右，-t 不会去拉 providers。
	// 留 30 秒是给慢盘的余量；万一 geodata 缺失、内核转去 geox-url 现下载，
	// 也该在这里快速失败并把原因报给用户，而不是干等两个 90 秒的下载超时。
	kernelCheckTimout = 30 * time.Second

	kernelStopTimeout = 5 * time.Second
)

// 内核认的 geodata 本地文件名（mihomo constant/path.go：MMDB() 认 Country.mmdb /
// geoip.db / geoip.metadb，GeoSite 认 GeoSite.dat）。安装包把它们放在内核旁边。
var geoDataFileNames = []string{"geoip.metadb", "GeoSite.dat"}

// 收紧运行目录权限并补齐 geodata，启动与校验共用。
//
// 内核解析 GEOIP / GEOSITE 规则时会就地读 geodata，缺文件就按 geox-url 同步下载
// （mihomo component/geodata/init.go 的 InitGeoIP / InitGeoSite，每文件 90 秒超时）。
// 面板下发的 geox-url 指向 GitHub，在目标网络里必然超时，整份配置随之校验失败、
// 内核起不来。安装包已随内核分发这两个库，补到运行目录即可让首次启动完全离线。
func prepareRunDir() error {
	if err := ensureRestrictedDir(runDir()); err != nil {
		return fmt.Errorf("准备运行目录失败: %w", err)
	}
	seedGeoData()
	return nil
}

// 已存在的不覆盖：内核 geo-auto-update 刷新过的那份比包内的新。
// 播种失败不阻断启动，内核仍可自行下载，只是慢且依赖网络能通。
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

// write 只落盘运行配置，不碰进程。热载路径：GUI 写盘后对控制面 PUT /configs。
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

// read 代读 run 目录下文件；GUI 无权直接打开该目录（0700 / 内核用户）。
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

// SIGINT 走 mihomo 自己的退出流程，utun 网卡、路由表与防火墙规则由它自行回收，
// 不需要另起一段清理代码；超时不退才升级为 SIGKILL。
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

// mihomo 校验失败时会先刷一堆 level=info 的初始化日志，真正的原因在最后一条
// level=error 上；取不到就退回整段输出，不能只给用户末行的“test failed”。
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

// 升级前也要用它验一遍待安装的内核，因此按可执行文件取而不是固定问安装目录那份
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
