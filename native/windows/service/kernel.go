//go:build windows

package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/windows"
)

const (
	kernelLogLines    = 800
	kernelCheckTimout = 15 * time.Second

	tunCleanupCommand = "tun-cleanup"
	tunCleanupTimeout = 15 * time.Second
)

// 清理网卡要调 wintun.dll，而内核刚被 TerminateProcess，网卡还挂在一个已死的
// 进程上。这一步曾把服务整个带走：SCM 记 7031「服务意外地终止」、Application
// 日志里没有对应的 WER 记录——正是 Go 运行时自己接住原生异常后 exit(2) 的表现。
// 放到子进程里做：崩了只损失子进程，服务继续在管道上待命，
// 客户端也就不会因为服务重启窗口而报「后台服务未运行」。
func cleanupTunAdapter() {
	exe, err := os.Executable()
	if err != nil {
		logf("定位自身可执行文件失败，改为进程内清理 TUN 网卡: %v", err)
		removeTunAdapter()
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), tunCleanupTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, exe, tunCleanupCommand)
	cmd.SysProcAttr = &windows.SysProcAttr{
		HideWindow:    true,
		CreationFlags: windows.CREATE_NO_WINDOW,
	}

	if out, err := cmd.CombinedOutput(); err != nil {
		logf("清理 TUN 网卡的子进程异常退出: %v %s", err, strings.TrimSpace(string(out)))
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

func (k *kernelManager) start(config string) error {
	if _, err := os.Stat(kernelPath()); err != nil {
		return fmt.Errorf("内核程序缺失: %s", kernelPath())
	}
	if err := ensureRestrictedDir(runDir()); err != nil {
		return fmt.Errorf("准备运行目录失败: %w", err)
	}
	if err := os.WriteFile(configPath(), []byte(config), 0o600); err != nil {
		return fmt.Errorf("写入配置失败: %w", err)
	}

	k.stop()

	k.mu.Lock()
	defer k.mu.Unlock()

	cmd := exec.Command(kernelPath(), "run", "-c", configPath(), "-D", runDir(), "--disable-color")
	cmd.Dir = runDir()
	cmd.SysProcAttr = &windows.SysProcAttr{
		HideWindow:    true,
		CreationFlags: windows.CREATE_NO_WINDOW,
	}

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
		k.running = false
		k.exitCode = cmd.ProcessState.ExitCode()
		if err != nil && !k.stopping {
			k.lastErr = err.Error()
		}
		graceful := k.stopping
		k.mu.Unlock()

		// 非正常退出时 sing-box 来不及销毁网卡
		if !graceful {
			cleanupTunAdapter()
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

// Windows 无法向子进程投递 SIGINT，只能 TerminateProcess，
// 内核走不到自身清理流程，网卡与路由靠 removeTunAdapter 补救。
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

	_ = process.Kill()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
	}
	cleanupTunAdapter()
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
	if err := ensureRestrictedDir(runDir()); err != nil {
		return fmt.Errorf("准备运行目录失败: %w", err)
	}

	path := filepath.Join(runDir(), "config.check.json")
	if err := os.WriteFile(path, []byte(config), 0o600); err != nil {
		return fmt.Errorf("写入待校验配置失败: %w", err)
	}
	defer os.Remove(path)

	ctx, cancel := context.WithTimeout(context.Background(), kernelCheckTimout)
	defer cancel()

	cmd := exec.CommandContext(ctx, kernelPath(), "check", "-c", path, "-D", runDir(), "--disable-color")
	cmd.SysProcAttr = &windows.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}

	out, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	if message := strings.TrimSpace(string(out)); message != "" {
		return fmt.Errorf("%s", message)
	}
	return err
}

func (k *kernelManager) kernelVersion() string {
	return kernelVersionOf(kernelPath())
}

// 升级前也要用它验一遍待安装的内核，因此按可执行文件取而不是固定问安装目录那份
func kernelVersionOf(exe string) string {
	cmd := exec.Command(exe, "version")
	cmd.SysProcAttr = &windows.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}

	out, err := cmd.Output()
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
