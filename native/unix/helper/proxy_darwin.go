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
	"*.lan",
	"*.home.arpa",
	"*.internal",
	"*.localdomain",
}

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

func (p *proxyManager) set(port int, clientPID int, bypass []string) error {
	services, err := activeServices()
	if err != nil {
		return err
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	// 已记录的服务保留最早的原值，不要用被自己改过的值覆盖；连接后新出现的服务须在改写前补记，否则断开时漏还原
	snapshot, err := loadSnapshot()
	if errors.Is(err, os.ErrNotExist) {
		snapshot, err = proxySnapshot{}, nil
	}
	if err != nil {
		return err
	}
	if fresh := unrecordedServices(snapshot, services); len(fresh) > 0 {
		added, err := captureSnapshot(fresh, clientPID)
		if err != nil {
			return err
		}
		added.Services = append(snapshot.Services, added.Services...)
		if err := saveSnapshot(added); err != nil {
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
		if err := networksetup(append([]string{"-setproxybypassdomains", service}, effectiveBypass(bypass)...)...); err != nil {
			return err
		}
	}
	return nil
}

func unrecordedServices(snapshot proxySnapshot, services []string) []string {
	recorded := make(map[string]bool, len(snapshot.Services))
	for _, service := range snapshot.Services {
		recorded[service.Name] = true
	}
	var fresh []string
	for _, service := range services {
		if !recorded[service] {
			fresh = append(fresh, service)
		}
	}
	return fresh
}

func effectiveBypass(items []string) []string {
	out := make([]string, 0, len(items))
	for _, item := range items {
		item = strings.TrimSpace(item)
		if item != "" {
			out = append(out, item)
		}
	}
	// 空列表是旧版 GUI 或漏传，不能清空例外，否则局域网会进代理
	if len(out) == 0 {
		return proxyBypass
	}
	return out
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

	listed, err := listedServices()
	if err != nil {
		return err
	}
	present := make(map[string]bool, len(listed))
	for _, name := range listed {
		present[strings.TrimPrefix(name, "*")] = true
	}

	var failures []error
	for _, service := range snapshot.Services {
		if !present[service.Name] {
			logf("快照中的网络服务 %s 已不存在，跳过还原", service.Name)
			continue
		}
		for index, proxy := range managedProxies {
			failures = append(failures, restoreEntry(service.Name, proxy.set, proxy.state, service.Proxies[index]))
		}
		// 原本没有例外域名时要清空，networksetup 用空串表示清空
		bypass := service.Bypass
		if len(bypass) == 0 {
			bypass = []string{""}
		}
		if err := networksetup(append([]string{"-setproxybypassdomains", service.Name}, bypass...)...); err != nil {
			failures = append(failures, fmt.Errorf("还原 %s 的代理例外失败: %w", service.Name, err))
		}
	}
	if err := errors.Join(failures...); err != nil {
		return err
	}

	return os.Remove(snapshotPath())
}

type proxyState struct {
	Enabled         bool   `json:"enabled"`
	Server          string `json:"server"`
	SnapshotPresent bool   `json:"snapshot_present"`
}

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

func restoreEntry(service, setter, stateSetter string, entry proxyEntry) error {
	var failures []error
	// networksetup 不接受空服务器地址，原本就没配过的只能关掉状态
	if entry.Server != "" {
		if err := networksetup(setter, service, entry.Server, strconv.Itoa(entry.Port)); err != nil {
			failures = append(failures, fmt.Errorf("还原 %s 的 %s 失败: %w", service, setter, err))
		}
	}
	state := "off"
	if entry.Enabled {
		state = "on"
	}
	if err := networksetup(stateSetter, service, state); err != nil {
		failures = append(failures, fmt.Errorf("还原 %s 的 %s 失败: %w", service, stateSetter, err))
	}
	return errors.Join(failures...)
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
	return loadSnapshotFile(snapshotPath())
}

func loadSnapshotFile(path string) (proxySnapshot, error) {
	var snapshot proxySnapshot
	data, err := os.ReadFile(path)
	if err != nil {
		return snapshot, err
	}
	if err := json.Unmarshal(data, &snapshot); err != nil {
		return snapshot, discardSnapshot(path, fmt.Errorf("代理快照已损坏: %w", err))
	}
	if len(snapshot.Services) == 0 {
		return snapshot, discardSnapshot(path, fmt.Errorf("代理快照没有记录任何网络服务"))
	}
	for _, service := range snapshot.Services {
		if len(service.Proxies) != len(managedProxies) {
			return snapshot, discardSnapshot(path, fmt.Errorf("代理快照与当前版本不匹配"))
		}
	}
	return snapshot, nil
}

func discardSnapshot(path string, reason error) error {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return errors.Join(reason, err)
	}
	logf("%v，已删除", reason)
	return fmt.Errorf("%w: %w", reason, os.ErrNotExist)
}

func saveSnapshot(snapshot proxySnapshot) error {
	if err := prepareRunRoot(); err != nil {
		return err
	}
	data, err := json.Marshal(snapshot)
	if err != nil {
		return err
	}
	return writeSnapshotFile(snapshotPath(), data)
}

func writeSnapshotFile(path string, data []byte) error {
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, data, 0o600); err != nil {
		os.Remove(temporary)
		return err
	}
	if err := os.Rename(temporary, path); err != nil {
		os.Remove(temporary)
		return err
	}
	return nil
}

// 首行是说明文字，带 * 前缀的是已停用的服务
func listedServices() ([]string, error) {
	out, err := output("-listallnetworkservices")
	if err != nil {
		return nil, err
	}

	var services []string
	for index, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if index == 0 || line == "" {
			continue
		}
		services = append(services, line)
	}
	return services, nil
}

func activeServices() ([]string, error) {
	listed, err := listedServices()
	if err != nil {
		return nil, err
	}

	var services []string
	for _, line := range listed {
		if !strings.HasPrefix(line, "*") {
			services = append(services, line)
		}
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
