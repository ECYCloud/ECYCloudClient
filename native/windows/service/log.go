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

// panic 会带走整个服务进程，没人还原系统代理
func guard(what string) {
	if r := recover(); r != nil {
		logf("%s 出现异常: %v\n%s", what, r, debug.Stack())
	}
}

// Go 运行时致命错误只写 fd 2；服务没有控制台，必须把 stderr 接到文件
func redirectStderr() {
	if err := prepareDataDir(); err != nil {
		return
	}

	file, err := os.OpenFile(fatalLogPath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
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

	if err := prepareDataDir(); err != nil {
		return
	}
	if info, err := os.Stat(serviceLogPath()); err == nil && info.Size() > logMaxBytes {
		os.Remove(serviceLogPath())
	}

	file, err := os.OpenFile(serviceLogPath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	defer file.Close()

	fmt.Fprintf(file, "%s %s\n", time.Now().Format("2006-01-02 15:04:05"), fmt.Sprintf(format, args...))
}
