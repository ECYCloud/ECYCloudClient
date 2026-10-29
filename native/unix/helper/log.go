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

func guard(what string) {
	if r := recover(); r != nil {
		logf("%s 出现异常: %v\n%s", what, r, debug.Stack())
	}
}

func logf(format string, args ...any) {
	logMu.Lock()
	defer logMu.Unlock()

	if err := ensureDataDir(); err != nil {
		return
	}
	if info, err := os.Stat(helperLogPath()); err == nil && info.Size() > logMaxBytes {
		os.Remove(helperLogPath())
	}

	file, err := os.OpenFile(helperLogPath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	defer file.Close()

	fmt.Fprintf(file, "%s %s\n", time.Now().Format("2006-01-02 15:04:05"), fmt.Sprintf(format, args...))
}
