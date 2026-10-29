//go:build windows

package main

import (
	"bufio"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/Microsoft/go-winio"
)

const (
	pipePath       = `\\.\pipe\ECYCloudService`
	maxRequestSize = 4 << 20
	// 管道对交互用户开放，必须限时读完
	requestReadTimeout   = 10 * time.Second
	responseWriteTimeout = 10 * time.Second
	maxConcurrentClients = 16
)

type request struct {
	Command  string `json:"command"`
	CacheKey string `json:"cache_key"`
	// 调用方自填，不可信；各分支用管道对端 PID
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

	mu        sync.RWMutex
	owner     string
	watched   int
	closing   bool
	operation sync.Mutex

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

	pid, err := pipeClientPID(conn)
	if err != nil {
		logf("识别管道客户端失败: %v", err)
		writeResponse(conn, response{Error: err.Error()})
		return
	}
	user, err := guiCallerSID(pid)
	if err != nil {
		logf("拒绝指令 %s: %v", req.Command, err)
		writeResponse(conn, response{Error: err.Error()})
		return
	}

	data, err := s.dispatch(req, pid, user)
	if err != nil {
		logf("命令 %s 失败: %v", req.Command, err)
		writeResponse(conn, response{Error: err.Error()})
		return
	}
	writeResponse(conn, response{OK: true, Data: data})
}

func (s *server) dispatch(req request, pid int, user string) (any, error) {
	if err := s.lockSession(pid, user); err != nil {
		return nil, err
	}
	defer s.mu.RUnlock()
	if req.Command == "kernel.upgrade.progress" {
		return s.upgradeProgress(), nil
	}
	s.operation.Lock()
	defer s.operation.Unlock()
	switch req.Command {
	case "kernel.upgrade.commit":
		if err := commitKernelUpgrade(); err != nil {
			return nil, err
		}
		return map[string]any{}, nil

	case "kernel.upgrade.rollback":
		if err := s.kernel.stop(); err != nil {
			return nil, fmt.Errorf("停止候选内核失败，不能回滚: %w", err)
		}
		if err := rollbackKernelUpgrade(); err != nil {
			return nil, err
		}
		return map[string]any{}, nil

	case "ping":
		return map[string]any{
			"version":     serviceVersion,
			"kernel":      s.kernel.kernelVersion(),
			"cache_ready": kernelCacheReady(),
		}, nil

	case "tun.ensure":
		ready, reason := ensureTunReady()
		return map[string]any{"ready": ready, "reason": reason}, nil

	case "kernel.bind":
		if err := s.bindCache(req.CacheKey, user); err != nil {
			return nil, err
		}
		return map[string]any{}, nil

	case "kernel.start":
		if strings.TrimSpace(req.Config) == "" {
			return nil, fmt.Errorf("缺少配置内容")
		}
		if err := s.kernel.start(req.Config); err != nil {
			return nil, err
		}
		return map[string]any{}, nil

	case "kernel.stop":
		if err := s.kernel.stop(); err != nil {
			return nil, err
		}
		return map[string]any{}, nil

	case "kernel.clear":
		if err := s.clearRuntime(); err != nil {
			return nil, err
		}
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

	case "proxy.set":
		if req.Port <= 0 || req.Port > 65535 {
			return nil, fmt.Errorf("非法端口 %d", req.Port)
		}
		if err := s.proxy.set(req.Port, pid, user, req.Bypass); err != nil {
			return nil, err
		}
		return map[string]any{}, nil

	case "proxy.restore":
		if err := s.proxy.restore(); err != nil {
			return nil, err
		}
		return map[string]any{}, nil

	case "proxy.state":
		return s.proxy.state(user)

	default:
		return nil, fmt.Errorf("未知指令 %q", req.Command)
	}
}

// 返回时持有读锁，清理必须等本账号正在执行的请求全部结束。
func (s *server) lockSession(pid int, user string) error {
	if pid <= 0 || user == "" {
		return fmt.Errorf("无法识别客户端系统账号")
	}
	for {
		s.mu.RLock()
		if s.closing {
			s.mu.RUnlock()
			return fmt.Errorf("后台服务正在停止")
		}
		if s.owner != "" && s.owner != user {
			s.mu.RUnlock()
			return fmt.Errorf("另一系统账号正在使用客户端，请先退出该账号的客户端")
		}
		if s.owner == user && s.watched == pid {
			return nil
		}
		s.mu.RUnlock()

		s.mu.Lock()
		if !s.closing && (s.owner == "" || s.owner == user) {
			root, err := os.OpenRoot(dataDir())
			if err == nil {
				marker, readErr := root.ReadFile(".cache-owner")
				root.Close()
				if readErr == nil && !strings.HasPrefix(string(marker), user+"\n") {
					if err := s.clearRuntime(); err != nil {
						s.mu.Unlock()
						return err
					}
				} else if readErr != nil && !os.IsNotExist(readErr) {
					s.mu.Unlock()
					return readErr
				}
			} else if !os.IsNotExist(err) {
				s.mu.Unlock()
				return err
			}
			if err := watchProcess(pid, func() { s.onClientGone(pid) }); err != nil {
				s.mu.Unlock()
				return fmt.Errorf("监听 GUI 进程失败: %w", err)
			}
			s.owner, s.watched = user, pid
		}
		s.mu.Unlock()
	}
}

func (s *server) initialize() error {
	if err := prepareRunDir(); err != nil {
		return err
	}
	return s.resetSession()
}

func (s *server) resetSession() error {
	if err := s.clearRuntime(true); err != nil {
		return err
	}
	s.owner, s.watched = "", 0
	return nil
}

func (s *server) clearRuntime(preserveCache ...bool) error {
	if err := s.kernel.stop(); err != nil {
		return fmt.Errorf("停止旧内核失败，不能释放会话: %w", err)
	}
	if s.kernel.status(0).Running {
		return fmt.Errorf("旧内核尚未退出，不能释放会话")
	}
	if err := s.proxy.restore(); err != nil {
		return fmt.Errorf("还原系统代理失败，不能释放会话: %w", err)
	}
	if err := clearSessionFiles(dataDir(), preserveCache...); err != nil {
		return fmt.Errorf("清理旧运行数据失败，不能释放会话: %w", err)
	}
	s.kernel = newKernelManager()
	return nil
}

func (s *server) bindCache(key, user string) error {
	if len(key) != 64 {
		return fmt.Errorf("缓存身份格式错误")
	}
	if _, err := hex.DecodeString(key); err != nil {
		return fmt.Errorf("缓存身份格式错误")
	}
	if err := prepareRunDir(); err != nil {
		return err
	}
	identity := user + "\n" + key
	root, err := os.OpenRoot(dataDir())
	if err != nil {
		return err
	}
	old, readErr := root.ReadFile(".cache-owner")
	root.Close()
	if readErr == nil && string(old) == identity {
		return nil
	}
	if readErr != nil && !os.IsNotExist(readErr) {
		return readErr
	}
	if err := s.clearRuntime(); err != nil {
		return err
	}
	if err := prepareRunDir(); err != nil {
		return err
	}
	root, err = os.OpenRoot(dataDir())
	if err != nil {
		return err
	}
	defer root.Close()
	return root.WriteFile(".cache-owner", []byte(identity), 0600)
}

func clearSessionFiles(base string, preserveCache ...bool) error {
	root, err := os.OpenRoot(base)
	if err != nil {
		return err
	}
	defer root.Close()
	if len(preserveCache) > 0 && preserveCache[0] {
		if marker, err := root.ReadFile(".cache-owner"); err == nil && len(marker) > 0 {
			for _, name := range []string{"config.json", "config.check.json", "proxy-snapshot.json"} {
				if err := root.Remove("run/" + name); err != nil && !os.IsNotExist(err) {
					return err
				}
			}
			return nil
		}
	}
	if err := root.RemoveAll("run"); err != nil {
		return err
	}
	if err := root.Remove(".cache-owner"); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func (s *server) onClientGone(pid int) {
	defer guard("GUI 退出后的收尾")

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.watched != pid || s.closing {
		return
	}

	logf("GUI 进程 %d 已退出，开始收尾", pid)
	if err := s.resetSession(); err != nil {
		logf("会话收尾失败: %v", err)
	}
}

func (s *server) shutdown() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closing = true
	if err := s.resetSession(); err != nil {
		logf("停止服务时清理会话失败: %v", err)
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
	conn.SetWriteDeadline(time.Now().Add(responseWriteTimeout))
	conn.Write(append(data, '\n'))
}
