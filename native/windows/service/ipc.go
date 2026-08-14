//go:build windows

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"sync"

	"github.com/Microsoft/go-winio"
)

const (
	pipePath       = `\\.\pipe\ECYCloudService`
	maxRequestSize = 4 << 20
)

type request struct {
	Command string `json:"command"`
	// 调用方自己填的，不可信，仅为兼容旧版 GUI 的请求体保留；
	// 各分支一律用 dispatch 收到的、内核给出的真实连接进程 PID
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

	upgrading sync.Mutex
	progress  upgradeProgress
}

func newServer() *server {
	return &server{kernel: newKernelManager(), proxy: newProxyManager()}
}

func (s *server) listen() (net.Listener, error) {
	return winio.ListenPipe(pipePath, &winio.PipeConfig{
		SecurityDescriptor: pipeSDDL,
		InputBufferSize:    64 * 1024,
		OutputBufferSize:   64 * 1024,
	})
}

// 一条连接只处理一条请求，应答后必须关闭：GUI 侧以 EOF 判定应答结束
func (s *server) serve(listener net.Listener) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		go s.handle(conn)
	}
}

func (s *server) handle(conn net.Conn) {
	defer conn.Close()
	defer guard("处理客户端请求")

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

	pid, err := pipeClientPID(conn)
	if err != nil {
		logf("识别管道客户端失败: %v", err)
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
			"version":     serviceVersion,
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
		if err := verifyGUICaller(pid); err != nil {
			return nil, err
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
		if err := verifyGUICaller(pid); err != nil {
			return nil, err
		}
		if err := s.kernel.write(req.Config); err != nil {
			return nil, err
		}
		return map[string]any{}, nil

	case "kernel.read":
		if strings.TrimSpace(req.Path) == "" {
			return nil, fmt.Errorf("缺少路径")
		}
		if err := verifyGUICaller(pid); err != nil {
			return nil, err
		}
		content, err := s.kernel.read(req.Path)
		if err != nil {
			return nil, err
		}
		return map[string]any{"content": content}, nil

	case "kernel.upgrade":
		if err := verifyGUICaller(pid); err != nil {
			return nil, err
		}
		version, err := s.upgradeKernel(req.Version)
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

// GUI 被强杀时没人下达停止指令，只能由服务代为收尾
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
	conn.Write(append(data, '\n'))
}
