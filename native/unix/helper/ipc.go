//go:build darwin || linux

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	maxRequestSize = 4 << 20
	// 套接字对所有本地用户开放，必须限时读完
	requestReadTimeout   = 10 * time.Second
	responseWriteTimeout = 10 * time.Second
	maxConcurrentClients = 16
)

type request struct {
	Command string `json:"command"`
	// 调用方自填，不可信；各分支用套接字对端 PID
	PID       int      `json:"pid"`
	Config    string   `json:"config"`
	Path      string   `json:"path"`
	Port      int      `json:"port"`
	Bypass    []string `json:"bypass"`
	LogCursor int      `json:"log_cursor"`
	Version   string   `json:"version"`
}

type response struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
	Data  any    `json:"data,omitempty"`
}

type upgradeProgress struct {
	mu      sync.Mutex
	stage   string
	percent int
}

type server struct {
	kernel *kernelManager
	proxy  *proxyManager

	mu      sync.Mutex
	watched int

	slots chan struct{}

	upgrading sync.Mutex
	progress  upgradeProgress
}

func newServer() *server {
	return &server{
		kernel: newKernelManager(),
		proxy:  newProxyManager(),
		slots:  make(chan struct{}, maxConcurrentClients),
	}
}

// 套接字对所有本地用户开放，准入靠 verifyGUICaller 核对接可执行文件路径
func (s *server) listen() (net.Listener, error) {
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o755); err != nil {
		return nil, fmt.Errorf("准备套接字目录失败: %w", err)
	}
	// 上次异常退出会留下套接字文件，不删就绑不上
	os.Remove(socketPath)

	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(socketPath, 0o666); err != nil {
		listener.Close()
		return nil, fmt.Errorf("放开套接字权限失败: %w", err)
	}
	return listener, nil
}

// 一条连接只处理一条请求，应答后必须关闭：GUI 侧以 EOF 判定应答结束
func (s *server) serve(listener net.Listener) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		select {
		case s.slots <- struct{}{}:
			go func() {
				defer func() { <-s.slots }()
				s.handle(conn)
			}()
		default:
			conn.Close()
		}
	}
}

func (s *server) handle(conn net.Conn) {
	defer conn.Close()
	defer guard("处理客户端请求")

	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return
	}

	conn.SetReadDeadline(time.Now().Add(requestReadTimeout))
	reader := bufio.NewReaderSize(conn, 64*1024)
	line, err := readLine(reader)
	if err != nil {
		return
	}

	var req request
	if err := json.Unmarshal([]byte(line), &req); err != nil {
		writeResponse(conn, response{Error: fmt.Sprintf("请求格式错误: %v", err)})
		return
	}

	pid, err := peerPID(unixConn)
	if err != nil {
		logf("识别套接字客户端失败: %v", err)
		writeResponse(conn, response{Error: err.Error()})
		return
	}
	if err := verifyGUICaller(pid); err != nil {
		logf("拒绝指令 %s: %v", req.Command, err)
		writeResponse(conn, response{Error: err.Error()})
		return
	}

	data, err := s.dispatch(req, pid)
	if err != nil {
		logf("命令 %s 失败: %v", req.Command, err)
		writeResponse(conn, response{Error: err.Error()})
		return
	}
	writeResponse(conn, response{OK: true, Data: data})
}

func (s *server) dispatch(req request, pid int) (any, error) {
	switch req.Command {
	case "ping":
		return map[string]any{
			"version":     helperVersion,
			"kernel":      s.kernel.kernelVersion(),
			"cache_ready": kernelCacheReady(),
		}, nil

	case "tun.ensure":
		ready, reason := ensureTunReady()
		return map[string]any{"ready": ready, "reason": reason}, nil

	case "kernel.start":
		if strings.TrimSpace(req.Config) == "" {
			return nil, fmt.Errorf("缺少配置内容")
		}
		if err := s.kernel.start(req.Config); err != nil {
			return nil, err
		}
		s.watchClient(pid)
		return map[string]any{}, nil

	case "kernel.stop":
		s.kernel.stop()
		return map[string]any{}, nil

	case "kernel.status":
		return s.kernel.status(req.LogCursor), nil

	case "kernel.check":
		if err := s.kernel.check(req.Config); err != nil {
			return map[string]any{"valid": false, "error": err.Error()}, nil
		}
		return map[string]any{"valid": true}, nil

	case "kernel.write":
		if strings.TrimSpace(req.Config) == "" {
			return nil, fmt.Errorf("缺少配置内容")
		}
		if err := s.kernel.write(req.Config); err != nil {
			return nil, err
		}
		return map[string]any{}, nil

	case "kernel.read":
		if strings.TrimSpace(req.Path) == "" {
			return nil, fmt.Errorf("缺少路径")
		}
		content, err := s.kernel.read(req.Path)
		if err != nil {
			return nil, err
		}
		return map[string]any{"content": content}, nil

	case "kernel.upgrade":
		version, err := s.upgradeKernel(req.Version, req.Port)
		if err != nil {
			return nil, err
		}
		return map[string]any{"version": version}, nil

	case "kernel.upgrade.progress":
		return s.upgradeProgress(), nil

	case "proxy.set":
		if req.Port <= 0 || req.Port > 65535 {
			return nil, fmt.Errorf("非法端口 %d", req.Port)
		}
		if err := s.proxy.set(req.Port, pid, req.Bypass); err != nil {
			return nil, err
		}
		s.watchClient(pid)
		return map[string]any{}, nil

	case "proxy.restore":
		if err := s.proxy.restore(); err != nil {
			return nil, err
		}
		return map[string]any{}, nil

	case "proxy.state":
		return s.proxy.state(pid)

	default:
		return nil, fmt.Errorf("未知指令 %q", req.Command)
	}
}

// GUI 被强杀时没人下达停止指令，只能由 helper 代为收尾
func (s *server) watchClient(pid int) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if pid <= 0 || pid == s.watched {
		return
	}
	if err := watchProcess(pid, func() { s.onClientGone(pid) }); err != nil {
		logf("监听 GUI 进程失败: %v", err)
		return
	}
	s.watched = pid
}

func (s *server) onClientGone(pid int) {
	defer guard("GUI 退出后的收尾")

	s.mu.Lock()
	if s.watched != pid {
		s.mu.Unlock()
		return
	}
	s.watched = 0
	s.mu.Unlock()

	logf("GUI 进程 %d 已退出，开始收尾", pid)
	s.kernel.stop()
	if err := s.proxy.restore(); err != nil {
		logf("兜底还原系统代理失败: %v", err)
	}
}

func (s *server) shutdown() {
	s.kernel.stop()
	if err := s.proxy.restore(); err != nil {
		logf("停止服务时还原系统代理失败: %v", err)
	}
	os.Remove(socketPath)
}

func readLine(reader *bufio.Reader) (string, error) {
	var builder strings.Builder
	for {
		chunk, more, err := reader.ReadLine()
		if err != nil {
			return "", err
		}
		if builder.Len()+len(chunk) > maxRequestSize {
			return "", fmt.Errorf("请求过大")
		}
		builder.Write(chunk)
		if !more {
			return builder.String(), nil
		}
	}
}

func writeResponse(conn net.Conn, resp response) {
	data, err := json.Marshal(resp)
	if err != nil {
		return
	}
	conn.SetWriteDeadline(time.Now().Add(responseWriteTimeout))
	conn.Write(append(data, '\n'))
}
