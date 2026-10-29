package kernel

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

var logOwnerPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)
var logFilePattern = regexp.MustCompile(`^app-\d{4}-\d{2}-\d{2}\.log$`)
var logLevels = []string{"debug", "info", "warning", "error", "silent"}

func rulePaths(data []byte) map[string]string {
	var config struct {
		Providers map[string]struct {
			Path string `json:"path"`
		} `json:"rule-providers"`
	}
	_ = json.Unmarshal(data, &config)
	result := map[string]string{}
	for name, provider := range config.Providers {
		result[name] = provider.Path
	}
	return result
}

func validLogLevel(level string) bool {
	for _, candidate := range logLevels {
		if level == candidate {
			return true
		}
	}
	return false
}

type logStore struct {
	directory, level, day string
	file                  *os.File
	bytes                 int64
}

func newLogStore(owner, level, directory string) *logStore {
	return &logStore{directory: filepath.Join(filepath.Dir(directory), "Logs", owner), level: level}
}

func (s *logStore) close() {
	if s != nil && s.file != nil {
		_ = s.file.Close()
		s.file = nil
	}
}

func (s *logStore) append(entry logEntry) {
	if s == nil || s.level == "silent" {
		return
	}
	rank := func(level string) int {
		for i, item := range logLevels {
			if item == level {
				return i
			}
		}
		return -1
	}
	if rank(entry.Level) < rank(s.level) {
		return
	}
	today := entry.Time.Local().Format("2006-01-02")
	if today != s.day || s.file == nil {
		s.close()
		if os.MkdirAll(s.directory, 0700) != nil {
			return
		}
		oldest := entry.Time.Local().AddDate(0, 0, -29).Format("2006-01-02")
		items, _ := os.ReadDir(s.directory)
		for _, item := range items {
			if logFilePattern.MatchString(item.Name()) && item.Name()[4:14] < oldest {
				_ = os.Remove(filepath.Join(s.directory, item.Name()))
			}
		}
		file, err := os.OpenFile(filepath.Join(s.directory, "app-"+today+".log"), os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
		if err != nil {
			return
		}
		info, err := file.Stat()
		if err != nil || !info.Mode().IsRegular() {
			_ = file.Close()
			return
		}
		s.file, s.day, s.bytes = file, today, info.Size()
		if _, err = file.Seek(0, io.SeekEnd); err != nil {
			s.close()
			return
		}
	}
	line := entry.Time.Format(time.RFC3339Nano) + " [" + entry.Level + "] [mihomo] " + strings.ReplaceAll(entry.Message, "\n", " ") + "\n"
	if len(line) > 10*1024*1024 {
		return
	}
	if s.bytes+int64(len(line)) > 10*1024*1024 {
		// Packet Tunnel 扩展内存上限约 50 MB：保留的 8 MiB 尾部分块前移，不整段读入内存。
		keep := min(s.bytes, 8*1024*1024)
		offset := s.bytes - keep
		chunk := make([]byte, 64*1024)
		var written int64
		for written < keep {
			n, err := s.file.ReadAt(chunk[:min(int64(len(chunk)), keep-written)], offset+written)
			if n > 0 {
				if _, werr := s.file.WriteAt(chunk[:n], written); werr != nil {
					s.close()
					return
				}
				written += int64(n)
			}
			if err == io.EOF {
				break
			}
			if err != nil {
				s.close()
				return
			}
		}
		if s.file.Truncate(written) != nil {
			s.close()
			return
		}
		if _, err := s.file.Seek(written, io.SeekStart); err != nil {
			s.close()
			return
		}
		s.bytes = written
	}
	n, err := io.WriteString(s.file, line)
	s.bytes += int64(n)
	if err != nil {
		s.close()
	}
}
