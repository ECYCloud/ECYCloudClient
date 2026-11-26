//go:build windows

package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
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

	// 与原先 GUI 直接热载时的等待上限一致
	kernelReloadTimeout = 120 * time.Second
)

// mihomo MMDB() 认 Country.mmdb / geoip.db / geoip.metadb，GeoSite 认 GeoSite.dat
var geoDataFileNames = []string{"geoip.metadb", "GeoSite.dat"}

var dataDirReady atomic.Bool

func prepareRunRoot() error {
	if err := prepareDataDir(); err != nil {
		return err
	}
	if err := ensureRestrictedDir(runRoot()); err != nil {
		return fmt.Errorf("准备运行目录失败: %w", err)
	}
	return nil
}

func prepareRunDir() error {
	if err := prepareRunRoot(); err != nil {
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
		// 写完整再改名：直接写目标，中途被杀留下的半截文件会被当成已有文件沿用
		temp := target + ".tmp"
		err := copyFile(filepath.Join(installDir(), name), temp)
		if err == nil {
			err = os.Rename(temp, target)
		}
		if err != nil {
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

	control      kernelControl
	controlBound atomic.Bool
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
	config, err = withoutPanelPayloads(config)
	if err != nil {
		return err
	}
	if err := os.WriteFile(configPath(), []byte(config), 0o600); err != nil {
		return fmt.Errorf("写入配置失败: %w", err)
	}
	return nil
}

// 热载走特权侧：与 kernel.start 同一套净化落盘，再请内核按这份文件重载；GUI 不再向内核提交配置原文
func (k *kernelManager) reload(config string) error {
	k.mu.Lock()
	running := k.running
	k.mu.Unlock()
	if !running {
		return fmt.Errorf("内核未运行，无法热载")
	}
	if err := k.write(config); err != nil {
		return err
	}
	return notifyKernelReload(config)
}

func notifyKernelReload(config string) error {
	control, err := parseKernelControl(config)
	if err != nil {
		return err
	}
	// 请求体只给默认路径，内核读回的是刚净化落盘的配置
	status, body, err := control.send(http.MethodPut, "/configs?force=true", `{"path":""}`, kernelReloadTimeout)
	if err != nil {
		return fmt.Errorf("通知内核重载配置失败: %w", err)
	}
	if status != http.StatusNoContent && status != http.StatusOK {
		return fmt.Errorf("内核重载配置失败（HTTP %d）：%s", status, body)
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
	// unix / pipe 控制口不校验 secret，unix 还会先以特权身份删除配置给的任意路径；tls / doh 另开端口
	top["external-controller-unix"] = emptyString
	top["external-controller-pipe"] = emptyString
	top["external-controller-tls"] = emptyString
	top["external-doh-server"] = emptyString
	// 顶层入站口与端口转发会开出界面上不存在的监听，allow-lan 时还对局域网敞开
	for _, key := range []string{"port", "socks-port", "redir-port", "tproxy-port"} {
		top[key] = json.RawMessage(`0`)
	}
	top["tunnels"] = json.RawMessage(`[]`)
	// GUI 只在回环上开带口令的测速入站，控制面也只绑回环；其余写法即非官方配置
	if err := checkLoopbackInbounds(top); err != nil {
		return "", err
	}
	if err := checkHTTPSDownloads(top); err != nil {
		return "", err
	}
	if err := checkProviderPaths(top); err != nil {
		return "", err
	}

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
		"external-controller-unix", "external-controller-pipe", "external-controller-tls", "external-doh-server",
		"port", "socks-port", "redir-port", "tproxy-port", "tunnels",
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

func checkLoopbackInbounds(top map[string]json.RawMessage) error {
	if raw, ok := top["external-controller"]; ok {
		var address string
		if json.Unmarshal(raw, &address) != nil {
			return fmt.Errorf("external-controller 必须是地址字符串")
		}
		if host, _, err := net.SplitHostPort(address); address != "" && (err != nil || !loopbackHost(host)) {
			return fmt.Errorf("控制面只能绑定本机回环地址")
		}
	}
	if raw, ok := top["listeners"]; ok {
		var listeners []map[string]any
		if json.Unmarshal(raw, &listeners) != nil {
			return fmt.Errorf("listeners 必须是数组")
		}
		for _, listener := range listeners {
			listen, _ := listener["listen"].(string)
			kind, _ := listener["type"].(string)
			if !loopbackHost(listen) || (kind != "mixed" && kind != "http" && kind != "socks") {
				return fmt.Errorf("只允许本机回环上的代理入站")
			}
		}
	}
	return nil
}

// 明文下载会被链路上替换规则集、节点订阅与地理数据库：只检查不改写面板的值，与 GUI 结构检查同口径。
// 内核取 provider 字段时名字不分大小写（mihomo common/structure），URL、Url 一样会被拿去下载
func checkHTTPSDownloads(top map[string]json.RawMessage) error {
	var geox map[string]any
	if json.Unmarshal(top["geox-url"], &geox) == nil {
		for key, url := range geox {
			if !httpsURL(url) {
				return fmt.Errorf("geox-url「%s」必须使用 https", key)
			}
		}
	}
	for _, section := range []string{"proxy-providers", "rule-providers"} {
		var providers map[string]json.RawMessage
		if json.Unmarshal(top[section], &providers) != nil {
			continue
		}
		for name, raw := range providers {
			var fields map[string]any
			_ = json.Unmarshal(raw, &fields)
			for key, url := range fields {
				if strings.EqualFold(key, "url") && !httpsURL(url) {
					return fmt.Errorf("%s「%s」的下载地址必须使用 https", section, name)
				}
			}
		}
	}
	return nil
}

// 与 Dart 侧 ProfileInspector._safeProviderPath 同一份保留名单与规则：provider 只能落在运行目录内且不得覆盖客户端文件。
// 内核以特权身份下载落盘，盖掉 config.json 就能在下次热载或重启时带入未经净化的配置；字段名不分大小写（mihomo common/structure）
func checkProviderPaths(top map[string]json.RawMessage) error {
	for _, section := range []string{"proxy-providers", "rule-providers"} {
		var providers map[string]json.RawMessage
		if json.Unmarshal(top[section], &providers) != nil {
			continue
		}
		for name, raw := range providers {
			var fields map[string]any
			_ = json.Unmarshal(raw, &fields)
			for key, value := range fields {
				if path, ok := value.(string); strings.EqualFold(key, "path") && (!ok || !safeProviderPath(path)) {
					return fmt.Errorf("「%s」的保存路径必须位于运行目录内，且不能覆盖客户端文件", name)
				}
			}
		}
	}
	return nil
}

// ~ 可组成 Windows 8.3 短文件名（CONFIG~1.JSO），绕过按字面比对的保留文件名
var (
	unsafeProviderPathChars = regexp.MustCompile(`[\\:~\x00-\x1f\x7f]`)
	reservedDeviceName      = regexp.MustCompile(`(?i)^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)`)
	reservedClientFile      = regexp.MustCompile(`(?i)^(config\.json|config\.check\.json|cache\.db|proxy-snapshot\.json|geoip\.metadb|geosite\.dat|geoip\.dat|asn\.mmdb|bundlemrs\.7z)(\.|$)|^\.validate-`)
)

func safeProviderPath(path string) bool {
	if path == "" || strings.HasPrefix(path, "/") || unsafeProviderPathChars.MatchString(path) {
		return false
	}
	var parts []string
	for _, part := range strings.Split(path, "/") {
		if part != "." {
			parts = append(parts, part)
		}
	}
	if len(parts) == 0 {
		return false
	}
	for _, part := range parts {
		if part == "" || part == ".." || strings.HasSuffix(part, ".") || strings.HasSuffix(part, " ") || reservedDeviceName.MatchString(part) {
			return false
		}
	}
	return !reservedClientFile.MatchString(parts[0])
}

// 没有地址的本地 provider 不受影响
func httpsURL(value any) bool {
	text, ok := value.(string)
	text = strings.ToLower(strings.TrimSpace(text))
	return value == nil || (ok && (text == "" || strings.HasPrefix(text, "https://")))
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

// 节点已写成各自的文件，内核按 path 读取；payload 留在配置里只会被内核当作后备节点再解析一遍
func withoutPanelPayloads(config string) (string, error) {
	out, err := filterObject([]byte(config), func(key string, value json.RawMessage) (json.RawMessage, bool, error) {
		if key != "proxy-providers" || !bytes.HasPrefix(bytes.TrimSpace(value), []byte("{")) {
			return value, true, nil
		}
		providers, err := filterObject(value, func(name string, provider json.RawMessage) (json.RawMessage, bool, error) {
			if !strings.HasPrefix(name, "ecy-panel-") {
				return provider, true, nil
			}
			stripped, err := filterObject(provider, func(field string, value json.RawMessage) (json.RawMessage, bool, error) {
				return value, !strings.EqualFold(field, "payload"), nil
			})
			return stripped, true, err
		})
		return providers, true, err
	})
	if err != nil {
		return "", err
	}
	var pretty bytes.Buffer
	if err := json.Indent(&pretty, out, "", "  "); err != nil {
		return "", fmt.Errorf("重写配置失败: %w", err)
	}
	return pretty.String(), nil
}

// 按原有键顺序重写 JSON 对象，keep 为 false 的键被删除
func filterObject(raw []byte, edit func(key string, value json.RawMessage) (json.RawMessage, bool, error)) ([]byte, error) {
	keys, err := objectKeys(raw)
	if err != nil {
		return nil, err
	}
	var values map[string]json.RawMessage
	if err := json.Unmarshal(raw, &values); err != nil {
		return nil, fmt.Errorf("配置不是合法 JSON: %w", err)
	}
	var buf bytes.Buffer
	buf.WriteByte('{')
	for _, key := range keys {
		value, keep, err := edit(key, values[key])
		if err != nil {
			return nil, err
		}
		if !keep {
			continue
		}
		if buf.Len() > 1 {
			buf.WriteByte(',')
		}
		buf.WriteString(strconv.Quote(key))
		buf.WriteByte(':')
		buf.Write(value)
	}
	buf.WriteByte('}')
	return buf.Bytes(), nil
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
	// 内核在系统没有全局单播 IPv6 时会清空 tun.inet6-address（config/utils.go 的 verifyIP6），
	// 严格路由随即在 WFP 封掉全部 IPv6，连 ::1 都不通；只有 IPv4 的网络很常见，跳过这项检查
	cmd.Env = append(os.Environ(), "SKIP_SYSTEM_IPV6_CHECK=true")
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

	k.control, _ = parseKernelControl(config)
	k.controlBound.Store(false)
	k.cmd = cmd
	k.pid = cmd.Process.Pid
	k.running = true
	k.stopping = false
	k.exitCode = -1
	k.lastErr = ""
	k.done = make(chan struct{})

	var pumps sync.WaitGroup
	pumps.Add(2)
	go k.pump(stdout, &pumps, k.control.address)
	go k.pump(stderr, &pumps, k.control.address)

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

func (k *kernelManager) pump(r io.ReadCloser, wg *sync.WaitGroup, listening string) {
	defer wg.Done()
	defer guard("转存内核输出")
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		k.logs.append(line)
		if controlListening(line, listening) {
			k.controlBound.Store(true)
		}
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
	control := k.control
	k.mu.Unlock()

	// 被强制结束的内核不经 sing-tun 的 Close()，NLA 会留下同名网络档案；secret 只发给本次内核输出确认过的监听口
	if k.controlBound.Load() {
		if err := control.disableTun(); err != nil {
			logf("停内核前关闭 TUN 失败: %v", err)
		}
	}

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

func (k *kernelManager) check(config string) (string, error) {
	config, err := sanitizeKernelConfig(config)
	if err != nil {
		return err.Error(), nil
	}
	if err := prepareRunDir(); err != nil {
		return "", err
	}

	path := filepath.Join(runDir(), "config.check.json")
	if err := os.WriteFile(path, []byte(config), 0o600); err != nil {
		return "", fmt.Errorf("写入待校验配置失败: %w", err)
	}
	defer os.Remove(path)

	ctx, cancel := context.WithTimeout(context.Background(), kernelCheckTimout)
	defer cancel()

	cmd := exec.CommandContext(ctx, kernelPath(), "-t", "-f", path, "-d", runDir())
	cmd.SysProcAttr = &windows.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}

	out, err := cmd.CombinedOutput()
	return kernelCheckResult(ctx, out, err)
}

// 只有内核自己跑完并报出错误才算配置不合法；超时、被结束、起不来必须走 error（GUI 把 valid=false 当成配置不合法、不再重试）。
// Windows 上被其它程序结束的进程只剩退出码，只能靠有无错误行区分
func kernelCheckResult(ctx context.Context, out []byte, err error) (string, error) {
	if err == nil {
		return "", nil
	}
	var exit *exec.ExitError
	if reason := kernelCheckFailure(string(out)); reason != "" && ctx.Err() == nil && errors.As(err, &exit) {
		return reason, nil
	}
	if ctx.Err() != nil {
		err = ctx.Err()
	}
	return "", fmt.Errorf("配置校验未能完成: %w", err)
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
	return reason
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
