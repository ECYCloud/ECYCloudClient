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
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	kernelLogLines    = 800
	kernelCheckTimout = 15 * time.Second
	kernelStopTimeout = 5 * time.Second
)

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
	if err := writeKernelFile(configPath(), config); err != nil {
		return fmt.Errorf("写入配置失败: %w", err)
	}

	k.stop()

	k.mu.Lock()
	defer k.mu.Unlock()

	cmd := exec.Command(kernelPath(), "run", "-c", configPath(), "-D", runDir(), "--disable-color")
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

// SIGINT 走 sing-box 自己的退出流程，utun 网卡、路由表与防火墙规则由它自行回收，
// 不需要像 Windows 那样另起一段清理代码；超时不退才升级为 SIGKILL。
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
	if err := ensureRestrictedDir(runDir()); err != nil {
		return fmt.Errorf("准备运行目录失败: %w", err)
	}

	path := filepath.Join(runDir(), "config.check.json")
	if err := writeKernelFile(path, config); err != nil {
		return fmt.Errorf("写入待校验配置失败: %w", err)
	}
	defer os.Remove(path)

	ctx, cancel := context.WithTimeout(context.Background(), kernelCheckTimout)
	defer cancel()

	cmd := exec.CommandContext(ctx, kernelPath(), "check", "-c", path, "-D", runDir(), "--disable-color")
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
	out, err := exec.Command(exe, "version").Output()
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
