//go:build windows

package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

func TestMain(m *testing.M) {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case kernelSignalCommand:
			if err := signalKernelConsole(os.Args[2:]); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			os.Exit(0)
		case "kernel-signal-test":
			interrupt := make(chan os.Signal, 1)
			signal.Notify(interrupt, os.Interrupt)
			window, _, _ := windows.NewLazySystemDLL("kernel32.dll").NewProc("GetConsoleWindow").Call()
			visible, _, _ := windows.NewLazySystemDLL("user32.dll").NewProc("IsWindowVisible").Call(window)
			if window == 0 || visible != 0 {
				fmt.Println("控制台缺失或可见")
				os.Exit(2)
			}
			fmt.Println("ready")
			if len(os.Args) > 2 && os.Args[2] == "ignore" {
				for {
					time.Sleep(time.Hour)
				}
			}
			<-interrupt
			fmt.Println("saved")
			os.Exit(0)
		}
	}
	os.Exit(m.Run())
}

func startKernelSignalTestProcess(t *testing.T, ignore bool) (*kernelManager, <-chan string) {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	args := []string{"kernel-signal-test"}
	if ignore {
		args = append(args, "ignore")
	}
	cmd := exec.Command(exe, args...)
	cmd.SysProcAttr = &windows.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NEW_CONSOLE}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	k := newKernelManager()
	k.cmd = cmd
	k.pid = cmd.Process.Pid
	k.running = true
	k.done = make(chan struct{})
	lines := make(chan string, 2)
	go func() {
		defer close(k.done)
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			lines <- scanner.Text()
		}
		_ = cmd.Wait()
		k.mu.Lock()
		k.running = false
		k.exitCode = cmd.ProcessState.ExitCode()
		k.mu.Unlock()
	}()
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		<-k.done
	})
	select {
	case line := <-lines:
		if line != "ready" {
			t.Fatalf("子进程启动失败: %s", line)
		}
	case <-k.done:
		t.Fatal("子进程未就绪即退出")
	case <-time.After(5 * time.Second):
		t.Fatal("子进程启动超时")
	}
	return k, lines
}

func TestKernelStopSavesAndLeavesOtherConsoleRunning(t *testing.T) {
	prepareKernelSignalTestLogs(t)
	k, lines := startKernelSignalTestProcess(t, false)
	other, _ := startKernelSignalTestProcess(t, false)
	k.stop()
	if status := k.status(0); status.Running || status.ExitCode == nil || *status.ExitCode != 0 {
		logs, _ := os.ReadFile(serviceLogPath())
		t.Fatalf("内核未正常退出: %+v；服务日志: %s", status, logs)
	}
	select {
	case line := <-lines:
		if line != "saved" {
			t.Fatalf("退出前未保存状态: %s", line)
		}
	default:
		t.Fatal("退出前未保存状态")
	}
	select {
	case <-other.done:
		t.Fatal("停止信号影响了其他控制台")
	default:
	}
	other.stop()
}

func TestKernelStopKillsUnresponsiveProcess(t *testing.T) {
	prepareKernelSignalTestLogs(t)
	k, _ := startKernelSignalTestProcess(t, true)
	started := time.Now()
	k.stop()
	if elapsed := time.Since(started); elapsed < 5*time.Second || elapsed > 13*time.Second {
		logs, _ := os.ReadFile(serviceLogPath())
		t.Fatalf("停止等待时间不正确: %s；服务日志: %s", elapsed, logs)
	}
	if status := k.status(0); status.Running || status.ExitCode == nil || *status.ExitCode == 0 {
		t.Fatalf("无响应进程未被强制结束: %+v", status)
	}
}

func prepareKernelSignalTestLogs(t *testing.T) {
	t.Helper()
	t.Setenv("ProgramData", t.TempDir())
	if err := os.Mkdir(dataDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	dataDirReady.Store(true)
	t.Cleanup(func() { dataDirReady.Store(false) })
}
