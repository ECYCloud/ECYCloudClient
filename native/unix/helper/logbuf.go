//go:build darwin || linux

package main

import "sync"

// 游标全局单调递增，溢出丢弃的行体现为游标跳变，GUI 据此判断是否漏日志
type logBuffer struct {
	mu    sync.Mutex
	lines []string
	first int // lines[0] 对应的游标
	next  int // 下一行将要使用的游标
	limit int
}

func newLogBuffer(limit int) *logBuffer {
	return &logBuffer{lines: make([]string, 0, limit), limit: limit}
}

func (b *logBuffer) append(line string) {
	b.mu.Lock()
	defer b.mu.Unlock()

	b.lines = append(b.lines, line)
	b.next++
	if len(b.lines) > b.limit {
		drop := len(b.lines) - b.limit
		b.lines = append(b.lines[:0], b.lines[drop:]...)
		b.first += drop
	}
}

func (b *logBuffer) since(cursor int) ([]string, int) {
	b.mu.Lock()
	defer b.mu.Unlock()

	if cursor < b.first {
		cursor = b.first
	}
	if cursor >= b.next {
		return []string{}, b.next
	}

	out := make([]string, b.next-cursor)
	copy(out, b.lines[cursor-b.first:])
	return out, b.next
}
