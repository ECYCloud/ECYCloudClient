//go:build darwin || linux

package main

import (
	"fmt"
	"os"
	"runtime/debug"
	"sync"
	"time"
)

const logMaxBytes = 2 << 20

var logMu sync.Mutex

// 任何一个 goroutine panic 都会带走整个 helper 进程，而 helper 一停就没人还原系统代理、
// 客户端也会因为套接字消失而报「后台服务未运行」。请求处理与后台回调一律兜住，
// 把现场记进日志而不是让进程消失。
func guard(what string) {
	if r := recover(); r != nil {
		logf("%s 出现异常: %v\n%s", what, r, debug.Stack())
	}
}

func logf(format string, args ...any) {
	logMu.Lock()
	defer logMu.Unlock()

	if err := os.MkdirAll(dataDir(), 0o755); err != nil {
		return
	}
	if info, err := os.Stat(helperLogPath()); err == nil && info.Size() > logMaxBytes {
		os.Remove(helperLogPath())
	}

	file, err := os.OpenFile(helperLogPath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	defer file.Close()

	fmt.Fprintf(file, "%s %s\n", time.Now().Format("2006-01-02 15:04:05"), fmt.Sprintf(format, args...))
}
