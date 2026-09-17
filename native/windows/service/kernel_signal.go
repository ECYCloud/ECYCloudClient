//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/windows"
)

const kernelSignalCommand = "kernel-break"

func interruptKernel(pid int) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, exe, kernelSignalCommand, strconv.Itoa(pid))
	cmd.SysProcAttr = &windows.SysProcAttr{HideWindow: true, CreationFlags: windows.DETACHED_PROCESS}
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// AttachConsole 会重置进程控制处理器，只能由独立辅助进程执行，不能影响服务或 debug 控制台。
func signalKernelConsole(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("缺少内核 PID")
	}
	pid, err := strconv.ParseUint(args[0], 10, 32)
	if err != nil || pid == 0 || pid == uint64(^uint32(0)) {
		return fmt.Errorf("无效的内核 PID")
	}

	kernel32 := windows.NewLazySystemDLL("kernel32.dll")
	attach := kernel32.NewProc("AttachConsole")
	free := kernel32.NewProc("FreeConsole")
	setHandler := kernel32.NewProc("SetConsoleCtrlHandler")
	if ok, _, callErr := attach.Call(uintptr(pid)); ok == 0 {
		return fmt.Errorf("连接内核控制台失败: %w", callErr)
	}
	defer free.Call()

	received := make(chan struct{}, 1)
	handler := windows.NewCallback(func(event uint32) uintptr {
		if event != windows.CTRL_BREAK_EVENT {
			return 0
		}
		select {
		case received <- struct{}{}:
		default:
		}
		return 1
	})
	if ok, _, callErr := setHandler.Call(handler, 1); ok == 0 {
		return fmt.Errorf("设置停止信号处理器失败: %w", callErr)
	}
	if err := windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, 0); err != nil {
		return fmt.Errorf("发送内核停止信号失败: %w", err)
	}
	select {
	case <-received:
		return nil
	case <-time.After(time.Second):
		return fmt.Errorf("等待停止信号分发超时")
	}
}
