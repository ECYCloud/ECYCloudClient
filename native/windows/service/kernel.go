//go:build windows

package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/sys/windows"
)

const (
	kernelLogLines = 800

	// 不得为容纳 geox-url 现下载而抬高：缺 geodata 时内核每文件 90 秒同步下载
	kernelCheckTimout = 30 * time.Second
)

// mihomo MMDB() 认 Country.mmdb / geoip.db / geoip.metadb，GeoSite 认 GeoSite.dat
var geoDataFileNames = []string{"geoip.metadb", "GeoSite.dat"}

var dataDirReady atomic.Bool

func prepareRunDir() error {
	if err := prepareDataDir(); err != nil {
		return err
	}
	if err := ensureRestrictedDir(runDir()); err != nil {
		return fmt.Errorf("准备运行目录失败: %w", err)
	}
	seedGeoData()
	return nil
}

// %ProgramData% 默认 ACL 允许普通用户造文件
func prepareDataDir() error {
	if dataDirReady.Load() {
		return nil
	}
	if err := ensureRestrictedDir(dataDir()); err != nil {
		return fmt.Errorf("准备数据目录失败: %w", err)
	}
	dataDirReady.Store(true)
	return nil
}

// 已存在的不覆盖：内核 geo-auto-update 刷新过的那份比包内的新
func seedGeoData() {
	for _, name := range geoDataFileNames {
		target := filepath.Join(runDir(), name)
		if _, err := os.Stat(target); err == nil {
			continue
		}
		if err := copyFile(filepath.Join(installDir(), name), target); err != nil {
			logf("播种 %s 失败，内核将自行下载: %v", name, err)
		}
	}
}

func ensureTunReady() (bool, string) {
	if _, err := os.Stat(kernelPath()); err != nil {
		return false, fmt.Sprintf("内核程序缺失: %s", kernelPath())
	}
	return true, ""
}

type kernelManager struct {
	mu       sync.Mutex
	cmd      *exec.Cmd
	pid      int
	running  bool
	stopping bool
	exitCode int
	lastErr  string
	logs     *logBuffer
	done     chan struct{}
}

func newKernelManager() *kernelManager {
	return &kernelManager{logs: newLogBuffer(kernelLogLines), exitCode: -1}
}

func (k *kernelManager) write(config string) error {
	config, err := sanitizeKernelConfig(config)
	if err != nil {
		return err
	}
	if err := prepareRunDir(); err != nil {
		return err
	}
	if err := writePanelProviders(config); err != nil {
		return err
	}
	if err := os.WriteFile(configPath(), []byte(config), 0o600); err != nil {
		return fmt.Errorf("写入配置失败: %w", err)
	}
	return nil
}

// GUI 身份已由系统核对，但注入官方 GUI 进程（Linux LD_PRELOAD / 未加固的 macOS DYLD 注入）后仍能下发任意配置。
// 特权侧在落盘前独立剥离会让内核以 SYSTEM/root 身份写盘或改系统的键，不把这道判断委托给 GUI（与 Dart 侧覆盖同口径）。
func sanitizeKernelConfig(config string) (string, error) {
	var top map[string]json.RawMessage
	if err := json.Unmarshal([]byte(config), &top); err != nil {
		return "", fmt.Errorf("配置不是合法 JSON: %w", err)
	}
	if top == nil {
		return "", fmt.Errorf("配置必须是 JSON 对象")
	}

	// external-ui / external-ui-url：内核会以特权身份下载并解压前端到运行目录
	emptyString, _ := json.Marshal("")
	top["external-ui"] = emptyString
	top["external-ui-url"] = emptyString
	top["ss-config"] = emptyString
	top["vmess-config"] = emptyString
	top["tuic-server"] = json.RawMessage(`{"enable":false}`)
	top["iptables"] = json.RawMessage(`{"enable":false}`)

	// ntp.write-to-system：内核会以特权身份改写系统时钟
	if raw, ok := top["ntp"]; ok {
		var ntp map[string]json.RawMessage
		if json.Unmarshal(raw, &ntp) == nil && ntp != nil {
			falseValue, _ := json.Marshal(false)
			ntp["write-to-system"] = falseValue
			if fixed, err := json.Marshal(ntp); err == nil {
				top["ntp"] = fixed
			}
		}
	}

	keys, err := objectKeys([]byte(config))
	if err != nil {
		return "", err
	}
	seen := map[string]bool{}
	for _, key := range keys {
		seen[key] = true
	}
	for _, key := range []string{
		"external-ui", "external-ui-url", "ss-config", "vmess-config", "tuic-server", "iptables",
	} {
		if !seen[key] {
			keys = append(keys, key)
		}
	}
	var buf bytes.Buffer
	buf.WriteByte('{')
	for i, key := range keys {
		if i > 0 {
			buf.WriteByte(',')
		}
		buf.WriteString(strconv.Quote(key))
		buf.WriteByte(':')
		buf.Write(top[key])
	}
	buf.WriteByte('}')
	var pretty bytes.Buffer
	if err := json.Indent(&pretty, buf.Bytes(), "", "  "); err != nil {
		return "", fmt.Errorf("重写配置失败: %w", err)
	}
	return pretty.String(), nil
}

func objectKeys(raw []byte) ([]string, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	tok, err := dec.Token()
	if err != nil {
		return nil, fmt.Errorf("配置不是合法 JSON: %w", err)
	}
	if tok != json.Delim('{') {
		return nil, fmt.Errorf("配置必须是 JSON 对象")
	}
	var keys []string
	seen := map[string]bool{}
	for dec.More() {
		keyTok, err := dec.Token()
		key, ok := keyTok.(string)
		if err != nil || !ok || dec.Decode(new(json.RawMessage)) != nil {
			return nil, fmt.Errorf("配置不是合法 JSON")
		}
		if !seen[key] {
			seen[key] = true
			keys = append(keys, key)
		}
	}
	if _, err = dec.Token(); err != nil || dec.More() {
		return nil, fmt.Errorf("配置不是合法 JSON")
	}
	return keys, nil
}

const maxRunFileBytes = 8 << 20

func panelProviderFiles(config string) (map[string][]byte, error) {
	var top struct {
		Providers map[string]json.RawMessage `json:"proxy-providers"`
	}
	if err := json.Unmarshal([]byte(config), &top); err != nil {
		return nil, err
	}
	files := map[string][]byte{}
	for name, raw := range top.Providers {
		if !strings.HasPrefix(name, "ecy-panel-") {
			continue
		}
		if name != "ecy-panel-nodes" && !regexp.MustCompile(`^ecy-panel-[a-f0-9]{64}$`).MatchString(name) {
			return nil, fmt.Errorf("节点文件名称不合法")
		}
		var provider struct {
			Type    string            `json:"type"`
			Path    string            `json:"path"`
			Payload []json.RawMessage `json:"payload"`
		}
		if err := json.Unmarshal(raw, &provider); err != nil {
			return nil, fmt.Errorf("节点文件配置不合法")
		}
		if provider.Type != "file" || provider.Path != name+".json" || len(provider.Payload) == 0 {
			return nil, fmt.Errorf("节点文件配置不合法")
		}
		data, err := json.Marshal(struct {
			Proxies []json.RawMessage `json:"proxies"`
		}{provider.Payload})
		if err != nil || len(data) > maxRunFileBytes {
			return nil, fmt.Errorf("节点文件过大或格式不合法")
		}
		files[provider.Path] = data
	}
	return files, nil
}

func writePanelProviders(config string) error {
	files, err := panelProviderFiles(config)
	if err != nil {
		return err
	}
	for name, data := range files {
		target := filepath.Join(runDir(), name)
		if info, err := os.Lstat(target); err == nil {
			if !info.Mode().IsRegular() {
				return fmt.Errorf("节点文件类型不可信")
			}
			file, err := os.Open(target)
			if err != nil {
				return err
			}
			var links windows.ByHandleFileInformation
			err = windows.GetFileInformationByHandle(windows.Handle(file.Fd()), &links)
			file.Close()
			if err != nil || links.NumberOfLinks != 1 {
				return fmt.Errorf("节点文件链接数不可信")
			}
		} else if !os.IsNotExist(err) {
			return err
		}
		if current, err := os.ReadFile(target); err == nil && bytes.Equal(current, data) {
			continue
		}
		temp, err := os.CreateTemp(runDir(), ".ecy-provider-")
		if err != nil {
			return err
		}
		tempPath := temp.Name()
		temp.Close()
		defer os.Remove(tempPath)
		if err := os.WriteFile(tempPath, data, 0o600); err != nil {
			return err
		}
		if err := os.Rename(tempPath, target); err != nil {
			return err
		}
	}
	return nil
}

// run 目录 DACL 仅 SYSTEM/管理员，GUI 只能由服务代读
func (k *kernelManager) read(rel string) (string, error) {
	path, err := resolveRunFile(rel)
	if err != nil {
		return "", err
	}
	root, err := os.OpenRoot(runDir())
	if err != nil {
		return "", err
	}
	defer root.Close()
	name, err := filepath.Rel(runDir(), path)
	if err != nil {
		return "", err
	}
	file, err := root.Open(name)
	if err != nil {
		if os.IsNotExist(err) {
			return "", fmt.Errorf("文件不存在")
		}
		return "", err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("只能读取普通文件")
	}
	if info.Size() > maxRunFileBytes {
		return "", fmt.Errorf("文件过大（超过 %d MiB）", maxRunFileBytes>>20)
	}
	data, err := io.ReadAll(io.LimitReader(file, maxRunFileBytes+1))
	if err != nil {
		return "", fmt.Errorf("读取失败: %w", err)
	}
	if len(data) > maxRunFileBytes {
		return "", fmt.Errorf("文件过大（超过 %d MiB）", maxRunFileBytes>>20)
	}
	return string(data), nil
}

func (k *kernelManager) start(config string) error {
	if _, err := os.Stat(kernelPath()); err != nil {
		return fmt.Errorf("内核程序缺失: %s", kernelPath())
	}
	if err := k.write(config); err != nil {
		return err
	}

	if err := k.stop(); err != nil {
		return fmt.Errorf("停止旧内核失败: %w", err)
	}

	k.mu.Lock()
	defer k.mu.Unlock()

	cmd := exec.Command(kernelPath(), "-d", runDir(), "-f", configPath())
	cmd.Dir = runDir()
	cmd.SysProcAttr = &windows.SysProcAttr{
		HideWindow:    true,
		CreationFlags: windows.CREATE_NEW_CONSOLE,
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("接管内核输出失败: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("接管内核错误输出失败: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("启动内核失败: %w", err)
	}

	k.cmd = cmd
	k.pid = cmd.Process.Pid
	k.running = true
	k.stopping = false
	k.exitCode = -1
	k.lastErr = ""
	k.done = make(chan struct{})

	var pumps sync.WaitGroup
	pumps.Add(2)
	go k.pump(stdout, &pumps)
	go k.pump(stderr, &pumps)

	done := k.done
	go func() {
		defer guard("等待内核退出")
		defer close(done)

		pumps.Wait()
		err := cmd.Wait()

		k.mu.Lock()
		k.running = false
		k.exitCode = cmd.ProcessState.ExitCode()
		if err != nil && !k.stopping {
			k.lastErr = err.Error()
		}
		k.mu.Unlock()
	}()

	return nil
}

func (k *kernelManager) pump(r io.ReadCloser, wg *sync.WaitGroup) {
	defer wg.Done()
	defer guard("转存内核输出")
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		k.logs.append(scanner.Text())
	}
}

func (k *kernelManager) stop() error {
	k.mu.Lock()
	if !k.running || k.cmd == nil || k.cmd.Process == nil {
		k.mu.Unlock()
		return nil
	}
	k.stopping = true
	process := k.cmd.Process
	done := k.done
	k.mu.Unlock()

	if err := interruptKernel(process.Pid); err == nil {
		select {
		case <-done:
			return nil
		case <-time.After(5 * time.Second):
			logf("内核 PID %d 未在停止期限内退出，将强制结束", process.Pid)
		}
	} else {
		select {
		case <-done:
			return nil
		default:
		}
		logf("通知内核 PID %d 正常停止失败，将强制结束: %v", process.Pid, err)
	}

	if err := process.Kill(); err != nil {
		select {
		case <-done:
			return nil
		default:
		}
		return fmt.Errorf("强制结束内核进程 %d 失败: %w", process.Pid, err)
	}

	select {
	case <-done:
		return nil
	case <-time.After(5 * time.Second):
		return fmt.Errorf("内核进程 %d 在停止期限内未回收", process.Pid)
	}
}

type kernelStatus struct {
	Running  bool     `json:"running"`
	PID      int      `json:"pid,omitempty"`
	ExitCode *int     `json:"exit_code,omitempty"`
	Error    string   `json:"error,omitempty"`
	LogLines []string `json:"log_lines"`
	LogCursr int      `json:"log_cursor"`
}

func (k *kernelManager) status(cursor int) kernelStatus {
	lines, next := k.logs.since(cursor)

	k.mu.Lock()
	defer k.mu.Unlock()

	status := kernelStatus{
		Running:  k.running,
		Error:    k.lastErr,
		LogLines: lines,
		LogCursr: next,
	}
	if k.running {
		status.PID = k.pid
	} else if k.exitCode >= 0 {
		code := k.exitCode
		status.ExitCode = &code
	}
	return status
}

func (k *kernelManager) check(config string) error {
	config, err := sanitizeKernelConfig(config)
	if err != nil {
		return err
	}
	if err := prepareRunDir(); err != nil {
		return err
	}

	path := filepath.Join(runDir(), "config.check.json")
	if err := os.WriteFile(path, []byte(config), 0o600); err != nil {
		return fmt.Errorf("写入待校验配置失败: %w", err)
	}
	defer os.Remove(path)

	ctx, cancel := context.WithTimeout(context.Background(), kernelCheckTimout)
	defer cancel()

	cmd := exec.CommandContext(ctx, kernelPath(), "-t", "-f", path, "-d", runDir())
	cmd.SysProcAttr = &windows.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}

	out, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	if message := kernelCheckFailure(string(out)); message != "" {
		return fmt.Errorf("%s", message)
	}
	return err
}

// mihomo 校验失败时真正原因在最后一条 level=error，末行只是 “test failed”
func kernelCheckFailure(out string) string {
	reason := ""
	for _, line := range strings.Split(out, "\n") {
		level, message, ok := splitKernelLogLine(line)
		if ok && message != "" && (level == "error" || level == "fatal") {
			reason = message
		}
	}
	if reason != "" {
		return reason
	}
	return strings.TrimSpace(out)
}

// 内核日志是 logrus 的 key=value 文本：time="..." level=error msg="..."
func splitKernelLogLine(line string) (level string, message string, ok bool) {
	level = logfmtValue(line, "level=")
	if level == "" {
		return "", "", false
	}
	return level, logfmtValue(line, "msg="), true
}

func logfmtValue(line string, key string) string {
	index := strings.Index(line, key)
	if index < 0 {
		return ""
	}
	rest := line[index+len(key):]
	if !strings.HasPrefix(rest, `"`) {
		if end := strings.IndexByte(rest, ' '); end >= 0 {
			return rest[:end]
		}
		return rest
	}
	if value, err := strconv.Unquote(rest[:quotedEnd(rest)]); err == nil {
		return value
	}
	return ""
}

func quotedEnd(rest string) int {
	for i := 1; i < len(rest); i++ {
		switch rest[i] {
		case '\\':
			i++
		case '"':
			return i + 1
		}
	}
	return len(rest)
}

func (k *kernelManager) kernelVersion() string {
	return kernelVersionOf(kernelPath())
}

func kernelVersionOf(exe string) string {
	cmd := exec.Command(exe, "-v")
	cmd.SysProcAttr = &windows.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}

	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			return line
		}
	}
	return ""
}
