//go:build darwin

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

const networksetupBin = "/usr/sbin/networksetup"

// 与 Windows 的 proxyBypass 同义：本机、私有网段与链路本地地址不走代理
var proxyBypass = []string{
	"127.0.0.1",
	"localhost",
	"*.local",
	"10.0.0.0/8",
	"172.16.0.0/12",
	"192.168.0.0/16",
	"169.254.0.0/16",
}

// networksetup 每种代理各有一套读写子命令，只有名字不同
var managedProxies = []struct {
	get   string
	set   string
	state string
}{
	{"-getwebproxy", "-setwebproxy", "-setwebproxystate"},
	{"-getsecurewebproxy", "-setsecurewebproxy", "-setsecurewebproxystate"},
}

type proxyEntry struct {
	Enabled bool   `json:"enabled"`
	Server  string `json:"server"`
	Port    int    `json:"port"`
}

type serviceSnapshot struct {
	Name    string       `json:"name"`
	Proxies []proxyEntry `json:"proxies"`
	Bypass  []string     `json:"bypass"`
}

type proxySnapshot struct {
	Services  []serviceSnapshot `json:"services"`
	WrittenAt string            `json:"written_at"`
	WriterPID int               `json:"writer_pid"`
}

type proxyManager struct {
	mu sync.Mutex
}

func newProxyManager() *proxyManager { return &proxyManager{} }

func (p *proxyManager) set(port int, clientPID int) error {
	services, err := activeServices()
	if err != nil {
		return err
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	// 已有快照说明上一次还没还原，保留最早的原值，不要用被自己改过的值覆盖
	if _, err := loadSnapshot(); err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		snapshot, err := captureSnapshot(services, clientPID)
		if err != nil {
			return err
		}
		if err := saveSnapshot(snapshot); err != nil {
			return err
		}
	}

	value := strconv.Itoa(port)
	for _, service := range services {
		for _, proxy := range managedProxies {
			if err := networksetup(proxy.set, service, "127.0.0.1", value); err != nil {
				return err
			}
		}
		if err := networksetup(append([]string{"-setproxybypassdomains", service}, proxyBypass...)...); err != nil {
			return err
		}
	}
	return nil
}

func (p *proxyManager) restore() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	snapshot, err := loadSnapshot()
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}

	for _, service := range snapshot.Services {
		for index, proxy := range managedProxies {
			restoreEntry(service.Name, proxy.set, proxy.state, service.Proxies[index])
		}
		// 原本没有例外域名时要清空，networksetup 用空串表示清空
		bypass := service.Bypass
		if len(bypass) == 0 {
			bypass = []string{""}
		}
		if err := networksetup(append([]string{"-setproxybypassdomains", service.Name}, bypass...)...); err != nil {
			logf("还原 %s 的代理例外失败: %v", service.Name, err)
		}
	}

	return os.Remove(snapshotPath())
}

type proxyState struct {
	Enabled         bool   `json:"enabled"`
	Server          string `json:"server"`
	SnapshotPresent bool   `json:"snapshot_present"`
}

// GUI 只用它判断"系统代理此刻是否指向本机"，取第一个在用的网络服务即可
func (p *proxyManager) state(_ int) (proxyState, error) {
	state := proxyState{}

	if _, err := loadSnapshot(); err == nil {
		state.SnapshotPresent = true
	} else if !errors.Is(err, os.ErrNotExist) {
		return state, err
	}

	services, err := activeServices()
	if err != nil || len(services) == 0 {
		return state, err
	}

	entry, err := readProxy(services[0], managedProxies[0].get)
	if err != nil {
		return state, err
	}
	state.Enabled = entry.Enabled
	if entry.Server != "" {
		state.Server = fmt.Sprintf("%s:%d", entry.Server, entry.Port)
	}
	return state, nil
}

func restoreEntry(service, setter, stateSetter string, entry proxyEntry) {
	// networksetup 不接受空服务器地址，原本就没配过的只能关掉状态
	if entry.Server != "" {
		if err := networksetup(setter, service, entry.Server, strconv.Itoa(entry.Port)); err != nil {
			logf("还原 %s 的 %s 失败: %v", service, setter, err)
		}
	}
	state := "off"
	if entry.Enabled {
		state = "on"
	}
	if err := networksetup(stateSetter, service, state); err != nil {
		logf("还原 %s 的 %s 失败: %v", service, stateSetter, err)
	}
}

func captureSnapshot(services []string, pid int) (proxySnapshot, error) {
	snapshot := proxySnapshot{
		WrittenAt: time.Now().Format(time.RFC3339),
		WriterPID: pid,
	}

	for _, service := range services {
		entry := serviceSnapshot{Name: service}
		for _, proxy := range managedProxies {
			value, err := readProxy(service, proxy.get)
			if err != nil {
				return snapshot, err
			}
			entry.Proxies = append(entry.Proxies, value)
		}

		bypass, err := readBypass(service)
		if err != nil {
			return snapshot, err
		}
		entry.Bypass = bypass
		snapshot.Services = append(snapshot.Services, entry)
	}
	return snapshot, nil
}

func loadSnapshot() (proxySnapshot, error) {
	var snapshot proxySnapshot
	data, err := os.ReadFile(snapshotPath())
	if err != nil {
		return snapshot, err
	}
	if err := json.Unmarshal(data, &snapshot); err != nil {
		return snapshot, fmt.Errorf("代理快照已损坏: %w", err)
	}
	if len(snapshot.Services) == 0 {
		return snapshot, fmt.Errorf("代理快照没有记录任何网络服务")
	}
	for _, service := range snapshot.Services {
		if len(service.Proxies) != len(managedProxies) {
			return snapshot, fmt.Errorf("代理快照与当前版本不匹配")
		}
	}
	return snapshot, nil
}

func saveSnapshot(snapshot proxySnapshot) error {
	if err := os.MkdirAll(dataDir(), 0o755); err != nil {
		return err
	}
	data, err := json.Marshal(snapshot)
	if err != nil {
		return err
	}
	return os.WriteFile(snapshotPath(), data, 0o644)
}

// 首行是说明文字，带 * 前缀的是已停用的服务，都不该动
func activeServices() ([]string, error) {
	out, err := output("-listallnetworkservices")
	if err != nil {
		return nil, err
	}

	var services []string
	for index, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if index == 0 || line == "" || strings.HasPrefix(line, "*") {
			continue
		}
		services = append(services, line)
	}
	if len(services) == 0 {
		return nil, fmt.Errorf("系统里没有已启用的网络服务")
	}
	return services, nil
}

// networksetup 的输出形如 "Enabled: Yes\nServer: 1.2.3.4\nPort: 8080\n..."
func readProxy(service, getter string) (proxyEntry, error) {
	entry := proxyEntry{}

	out, err := output(getter, service)
	if err != nil {
		return entry, err
	}
	for _, line := range strings.Split(out, "\n") {
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		value = strings.TrimSpace(value)
		switch strings.TrimSpace(key) {
		case "Enabled":
			entry.Enabled = strings.EqualFold(value, "Yes")
		case "Server":
			entry.Server = value
		case "Port":
			entry.Port, _ = strconv.Atoi(value)
		}
	}
	return entry, nil
}

// 没有例外域名时 networksetup 返回一句说明而不是空输出
func readBypass(service string) ([]string, error) {
	out, err := output("-getproxybypassdomains", service)
	if err != nil {
		return nil, err
	}

	var domains []string
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.Contains(line, "aren't any") {
			continue
		}
		domains = append(domains, line)
	}
	return domains, nil
}

func output(args ...string) (string, error) {
	out, err := exec.Command(networksetupBin, args...).Output()
	if err != nil {
		return "", fmt.Errorf("networksetup %s 失败: %w", strings.Join(args, " "), err)
	}
	return string(out), nil
}

func networksetup(args ...string) error {
	if out, err := exec.Command(networksetupBin, args...).CombinedOutput(); err != nil {
		if message := strings.TrimSpace(string(out)); message != "" {
			return fmt.Errorf("networksetup %s 失败: %s", strings.Join(args, " "), message)
		}
		return fmt.Errorf("networksetup %s 失败: %w", strings.Join(args, " "), err)
	}
	return nil
}
