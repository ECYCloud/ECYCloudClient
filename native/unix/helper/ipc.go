//go:build darwin || linux

package main

import (
	"bufio"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

// 读写当前登录会话运行目录的指令，必须先 kernel.bind
var sessionCommands = map[string]bool{
	"kernel.start":  true,
	"kernel.check":  true,
	"kernel.write":  true,
	"kernel.reload": true,
	"kernel.read":   true,
}

const (
	maxRequestSize = 4 << 20
	// 套接字对所有本地用户开放，必须限时读完
	requestReadTimeout   = 10 * time.Second
	responseWriteTimeout = 10 * time.Second
	maxConcurrentClients = 16
)

type request struct {
	Command  string `json:"command"`
	CacheKey string `json:"cache_key"`
	// 调用方自填，不可信；各分支用套接字对端 PID
	PID       int      `json:"pid"`
	Config    string   `json:"config"`
	Path      string   `json:"path"`
	Port      int      `json:"port"`
	Bypass    []string `json:"bypass"`
	LogCursor int      `json:"log_cursor"`
	Version   string   `json:"version"`
	Nonce     string   `json:"nonce"`
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
		accepted := time.Now()
		select {
		case s.slots <- struct{}{}:
			go func() {
				defer func() { <-s.slots }()
				s.handle(conn, accepted)
			}()
		default:
			conn.Close()
		}
	}
}

func (s *server) handle(conn net.Conn, accepted time.Time) {
	defer conn.Close()
	defer guard("处理客户端请求")

	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return
	}

	// 先认定调用方再读请求：读请求要等对端发完，期间对端可以 exec 成官方 GUI
	caller, err := peerIdentity(unixConn, accepted)
	if err != nil {
		logf("识别套接字客户端失败: %v", err)
		writeResponse(conn, response{Error: err.Error()})
		return
	}
	defer caller.close()
	if err := verifyGUICaller(caller.exe); err != nil {
		logf("拒绝进程 %d 的指令: %v", caller.pid, err)
		writeResponse(conn, response{Error: err.Error()})
		return
	}

	req, ok := readRequest(unixConn, caller)
	if !ok {
		return
	}

	data, err := s.dispatch(req, caller.pid, caller.user)
	if err != nil {
		logf("命令 %s 失败: %v", req.Command, err)
		writeResponse(conn, response{Error: err.Error()})
		return
	}
	writeResponse(conn, response{OK: true, Data: data})
}

// 请求必须带本次握手下发的随机数，且读完时对端仍是通过校验的那个调用方：
// 连上后预写请求再 exec 成官方 GUI，或由共享这条连接的其它进程代写，都会被拒绝
func readRequest(conn *net.UnixConn, caller *peer) (request, bool) {
	nonce := rand.Text()
	// 旧版 GUI 不认握手，只把收到的第一行当应答：ok 为假才能把提示带到界面
	writeResponse(conn, response{Error: "后台服务已更新，请重新打开客户端", Data: map[string]string{"nonce": nonce}})

	conn.SetReadDeadline(time.Now().Add(requestReadTimeout))
	reader := bufio.NewReaderSize(conn, 64*1024)
	line, err := readLine(reader)
	if err != nil {
		return request{}, false
	}
	if err := caller.confirm(conn); err != nil {
		logf("拒绝进程 %d 的指令: %v", caller.pid, err)
		return request{}, false
	}
	if err := requireLoneRequest(conn, reader.Buffered()); err != nil {
		logf("拒绝进程 %d 的指令: %v", caller.pid, err)
		return request{}, false
	}

	var req request
	if err := json.Unmarshal([]byte(line), &req); err != nil {
		writeResponse(conn, response{Error: fmt.Sprintf("请求格式错误: %v", err)})
		return request{}, false
	}
	if subtle.ConstantTimeCompare([]byte(req.Nonce), []byte(nonce)) != 1 {
		logf("拒绝进程 %d 的指令: 请求未带本次握手的随机数", caller.pid)
		return request{}, false
	}
	return req, true
}

// GUI 写完一行就等应答：之后还有数据或写端已关，说明另有进程在这条连接上读写
func requireLoneRequest(conn *net.UnixConn, buffered int) error {
	if buffered > 0 {
		return fmt.Errorf("请求之后还有多余数据")
	}
	raw, err := conn.SyscallConn()
	if err != nil {
		return err
	}
	var ready int
	var pollErr error
	if err := raw.Control(func(fd uintptr) {
		for {
			ready, pollErr = unix.Poll([]unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}, 0)
			if pollErr != unix.EINTR {
				return
			}
		}
	}); err != nil {
		return err
	}
	if pollErr != nil {
		return pollErr
	}
	if ready > 0 {
		return fmt.Errorf("请求之后还有多余数据或对端已关闭写入")
	}
	return nil
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
	if sessionCommands[req.Command] && activeSession == "" {
		return nil, fmt.Errorf("尚未绑定登录会话")
	}
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
			"version":     helperVersion,
			"kernel":      s.kernel.kernelVersion(),
			"cache_ready": kernelCacheReady(),
		}, nil

	case "tun.ensure":
		ready, reason := ensureTunReady()
		return map[string]any{"ready": ready, "reason": reason}, nil

	case "kernel.bind":
		if err := s.bindCache(req.CacheKey); err != nil {
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
		if err := s.endSession(req.CacheKey); err != nil {
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

	case "kernel.reload":
		if strings.TrimSpace(req.Config) == "" {
			return nil, fmt.Errorf("缺少配置内容")
		}
		if err := s.kernel.reload(req.Config); err != nil {
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
		if err := s.proxy.set(req.Port, pid, req.Bypass); err != nil {
			return nil, err
		}
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
	if err := prepareRunRoot(); err != nil {
		return err
	}
	if err := s.resetSession(); err != nil {
		return err
	}
	collectGarbage(runRoot())
	return nil
}

// 登录会话目录保留，同一会话再次绑定时复用其中的缓存与规则集
func (s *server) resetSession() error {
	if err := s.releaseKernel(); err != nil {
		return err
	}
	if activeSession != "" {
		dropRuntimeSecrets(runDir())
	}
	activeSession = ""
	s.owner, s.watched = "", 0
	return nil
}

// 面板账户退出：删掉带节点凭据的配置，规则集与 cache.db 留给同账号下次登录。
// 晚到的旧账号退出不能停掉已绑定的新账号
func (s *server) endSession(key string) error {
	if key != "" && !validSessionKey(key) {
		return fmt.Errorf("缓存身份格式错误")
	}
	if key != "" && key != activeSession {
		dropRuntimeSecrets(filepath.Join(runRoot(), key))
		return nil
	}
	if err := s.releaseKernel(); err != nil {
		return err
	}
	if activeSession != "" {
		dropRuntimeSecrets(runDir())
	}
	activeSession = ""
	collectGarbage(runRoot())
	return nil
}

func validSessionKey(key string) bool {
	_, err := hex.DecodeString(key)
	return len(key) == 64 && err == nil
}

func (s *server) releaseKernel() error {
	if err := s.kernel.stop(); err != nil {
		return fmt.Errorf("停止旧内核失败: %w", err)
	}
	if s.kernel.status(0).Running {
		return fmt.Errorf("旧内核尚未退出")
	}
	if err := s.proxy.restore(); err != nil {
		logf("还原系统代理失败，快照保留待下次还原: %v", err)
	}
	s.kernel = newKernelManager()
	return nil
}

func (s *server) bindCache(key string) error {
	if !validSessionKey(key) {
		return fmt.Errorf("缓存身份格式错误")
	}
	if key != activeSession {
		if err := s.releaseKernel(); err != nil {
			return err
		}
		activeSession = key
	}
	if err := prepareRunDir(); err != nil {
		return err
	}
	touchLastUsed(runDir())
	collectGarbage(runRoot())
	return nil
}

func dropRuntimeSecrets(dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if !os.IsNotExist(err) {
			logf("读取账号运行目录失败: %v", err)
		}
		return
	}
	for _, entry := range entries {
		name := entry.Name()
		if name != "config.json" && name != "config.check.json" &&
			!(strings.HasPrefix(name, "ecy-panel-") && strings.HasSuffix(name, ".json")) {
			continue
		}
		if err := os.Remove(filepath.Join(dir, name)); err != nil && !os.IsNotExist(err) {
			logf("删除运行密钥失败: %v", err)
		}
	}
}

// 账号目录超过这么久未用才回收；当前绑定的目录永不回收
const sessionRetention = 30 * 24 * time.Hour

const lastUsedName = ".last-used"

func touchLastUsed(dir string) {
	path := filepath.Join(dir, lastUsedName)
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|noFollow, 0o600)
	if err == nil {
		file.Close()
		now := time.Now()
		err = os.Chtimes(path, now, now)
	}
	if err != nil {
		logf("记录账号目录使用时间失败: %v", err)
	}
}

func recentlyUsed(dir string) bool {
	info, err := os.Lstat(filepath.Join(dir, lastUsedName))
	return err == nil && info.Mode().IsRegular() && time.Since(info.ModTime()) < sessionRetention
}

func collectGarbage(base string) {
	root, err := os.OpenRoot(base)
	if err != nil {
		if !os.IsNotExist(err) {
			logf("打开运行目录失败: %v", err)
		}
		return
	}
	defer root.Close()
	entries, err := fs.ReadDir(root.FS(), ".")
	if err != nil {
		logf("读取运行目录失败: %v", err)
	}
	for _, entry := range entries {
		name := entry.Name()
		if name == activeSession || name == filepath.Base(snapshotPath()) ||
			(entry.IsDir() && recentlyUsed(filepath.Join(base, name))) {
			continue
		}
		if err := root.RemoveAll(name); err != nil {
			logf("删除过期账号运行数据失败: %v", err)
		}
	}
	if err := os.Remove(filepath.Join(filepath.Dir(base), ".cache-owner")); err != nil && !os.IsNotExist(err) {
		logf("删除旧版缓存归属文件失败: %v", err)
	}
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
