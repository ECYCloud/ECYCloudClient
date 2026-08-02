//go:build windows

package main

import (
	"fmt"
	"os"
	"runtime/debug"
	"sync"
	"time"

	"golang.org/x/sys/windows"
)

const logMaxBytes = 2 << 20

var logMu sync.Mutex

// 任何一个 goroutine panic 都会带走整个服务进程，而服务一停就没人还原系统代理、
// 客户端也会因为管道消失而报「后台服务未运行」。请求处理与后台回调一律兜住，
// 把现场记进日志而不是让进程消失。
func guard(what string) {
	if r := recover(); r != nil {
		logf("%s 出现异常: %v\n%s", what, r, debug.Stack())
	}
}

// Go 运行时的致命错误（panic 未被 recover、原生异常、栈溢出）只写 fd 2，
// 服务进程没有控制台，这些信息会直接丢掉，事故后无从下手。
// 服务模式下先把标准错误接到文件上，运行时的 GetStdHandle 会拿到这个句柄。
func redirectStderr() {
	if err := os.MkdirAll(dataDir(), 0o755); err != nil {
		return
	}

	file, err := os.OpenFile(fatalLogPath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	if err := windows.SetStdHandle(windows.STD_ERROR_HANDLE, windows.Handle(file.Fd())); err != nil {
		file.Close()
		return
	}
	os.Stderr = file
}

func logf(format string, args ...any) {
	logMu.Lock()
	defer logMu.Unlock()

	if err := os.MkdirAll(dataDir(), 0o755); err != nil {
		return
	}
	if info, err := os.Stat(serviceLogPath()); err == nil && info.Size() > logMaxBytes {
		os.Remove(serviceLogPath())
	}

	file, err := os.OpenFile(serviceLogPath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	defer file.Close()

	fmt.Fprintf(file, "%s %s\n", time.Now().Format("2006-01-02 15:04:05"), fmt.Sprintf(format, args...))
}
