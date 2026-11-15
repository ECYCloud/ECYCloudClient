//go:build windows

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const (
	internetSettingsKey = `Software\Microsoft\Windows\CurrentVersion\Internet Settings`
	proxyBypass         = "localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;169.254.*;<local>"

	internetOptionRefresh         = 37
	internetOptionSettingsChanged = 39
)

// 指针为 nil 表示该值原本不存在，还原时应删除而不是写回空字符串
type proxySnapshot struct {
	UserSID   string  `json:"user_sid"`
	Enable    *uint32 `json:"proxy_enable"`
	Server    *string `json:"proxy_server"`
	Override  *string `json:"proxy_override"`
	WrittenAt string  `json:"written_at"`
	WriterPID int     `json:"writer_pid"`
}

type proxyManager struct {
	mu sync.Mutex
}

func newProxyManager() *proxyManager { return &proxyManager{} }

type deferredRestore struct {
	snapshot proxySnapshot
}

func (d *deferredRestore) Error() string {
	return fmt.Sprintf("系统账号 %s 的注册表未加载，系统代理待其下次连接再还原", d.snapshot.UserSID)
}

// 服务以 LocalSystem 运行，HKCU 是 SYSTEM 自己的 hive，必须按 SID 定位用户 hive
func openInternetSettings(sid string, access uint32) (registry.Key, error) {
	return registry.OpenKey(registry.USERS, sid+`\`+internetSettingsKey, access)
}

func hiveLoaded(sid string) bool {
	key, err := registry.OpenKey(registry.USERS, sid, registry.QUERY_VALUE)
	if err != nil {
		return !errors.Is(err, registry.ErrNotExist)
	}
	key.Close()
	return true
}

func (p *proxyManager) set(port int, clientPID int, sid string, bypass []string) error {
	key, err := openInternetSettings(sid, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		return fmt.Errorf("打开用户 Internet 设置失败: %w", err)
	}
	defer key.Close()

	p.mu.Lock()
	defer p.mu.Unlock()

	if !validSID(sid) {
		return fmt.Errorf("系统账号标识格式错误")
	}
	// 已有快照说明上一次还没还原，保留最早的原值，不要用被自己改过的值覆盖
	if _, err := loadSnapshot(snapshotPath(sid)); err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if err := saveSnapshot(captureSnapshot(key, sid, clientPID)); err != nil {
			return err
		}
	}

	if err := key.SetDWordValue("ProxyEnable", 1); err != nil {
		return fmt.Errorf("写入 ProxyEnable 失败: %w", err)
	}
	if err := key.SetStringValue("ProxyServer", fmt.Sprintf("127.0.0.1:%d", port)); err != nil {
		return fmt.Errorf("写入 ProxyServer 失败: %w", err)
	}
	if err := key.SetStringValue("ProxyOverride", joinBypass(bypass)); err != nil {
		return fmt.Errorf("写入 ProxyOverride 失败: %w", err)
	}
	notifySettingsChanged()
	return nil
}

func joinBypass(items []string) string {
	parts := make([]string, 0, len(items))
	for _, item := range items {
		item = strings.TrimSpace(item)
		if item != "" {
			parts = append(parts, item)
		}
	}
	// 空列表是旧版 GUI 或漏传，不能把 ProxyOverride 写成空串，否则局域网会进代理
	if len(parts) == 0 {
		return proxyBypass
	}
	return strings.Join(parts, ";")
}

func validSID(sid string) bool {
	return sidPattern.MatchString(sid)
}

var sidPattern = regexp.MustCompile(`^S-1(-[0-9]+)+$`)

func (p *proxyManager) restore(sid string) error {
	if !validSID(sid) {
		return fmt.Errorf("系统账号标识格式错误")
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return restoreSnapshot(snapshotPath(sid))
}

// 内核停下时把所有账号残留的快照都试着还原；对应账号未登录时延到下次
func (p *proxyManager) restoreAll() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	paths, err := filepath.Glob(filepath.Join(runRoot(), "proxy-snapshot*.json"))
	if err != nil {
		return err
	}
	var failures []error
	for _, path := range paths {
		failures = append(failures, restoreSnapshot(path))
	}
	return errors.Join(failures...)
}

func restoreSnapshot(path string) error {
	snapshot, err := loadSnapshot(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}

	key, err := openInternetSettings(snapshot.UserSID, registry.SET_VALUE)
	if err != nil {
		if !hiveLoaded(snapshot.UserSID) {
			return &deferredRestore{snapshot: snapshot}
		}
		return fmt.Errorf("打开用户 Internet 设置失败: %w", err)
	}
	defer key.Close()

	err = errors.Join(
		restoreDWord(key, "ProxyEnable", snapshot.Enable),
		restoreString(key, "ProxyServer", snapshot.Server),
		restoreString(key, "ProxyOverride", snapshot.Override),
	)
	notifySettingsChanged()
	if err != nil {
		return fmt.Errorf("还原用户代理设置失败: %w", err)
	}

	return os.Remove(path)
}

type proxyState struct {
	Enabled         bool   `json:"enabled"`
	Server          string `json:"server"`
	SnapshotPresent bool   `json:"snapshot_present"`
}

func (p *proxyManager) state(sid string) (proxyState, error) {
	state := proxyState{}

	if !validSID(sid) {
		return state, fmt.Errorf("系统账号标识格式错误")
	}
	if _, err := loadSnapshot(snapshotPath(sid)); err == nil {
		state.SnapshotPresent = true
	} else if !errors.Is(err, os.ErrNotExist) {
		return state, err
	}

	key, err := openInternetSettings(sid, registry.QUERY_VALUE)
	if err != nil {
		return state, fmt.Errorf("打开用户 Internet 设置失败: %w", err)
	}
	defer key.Close()

	if enable, _, err := key.GetIntegerValue("ProxyEnable"); err == nil {
		state.Enabled = enable != 0
	}
	if server, _, err := key.GetStringValue("ProxyServer"); err == nil {
		state.Server = server
	}
	return state, nil
}

func captureSnapshot(key registry.Key, sid string, pid int) proxySnapshot {
	snapshot := proxySnapshot{
		UserSID:   sid,
		WrittenAt: time.Now().Format(time.RFC3339),
		WriterPID: pid,
	}
	if enable, _, err := key.GetIntegerValue("ProxyEnable"); err == nil {
		value := uint32(enable)
		snapshot.Enable = &value
	}
	if server, _, err := key.GetStringValue("ProxyServer"); err == nil {
		snapshot.Server = &server
	}
	if override, _, err := key.GetStringValue("ProxyOverride"); err == nil {
		snapshot.Override = &override
	}
	return snapshot
}

func loadSnapshot(path string) (proxySnapshot, error) {
	var snapshot proxySnapshot
	data, err := os.ReadFile(path)
	if err != nil {
		return snapshot, err
	}
	if err := json.Unmarshal(data, &snapshot); err != nil {
		return snapshot, discardSnapshot(path, fmt.Errorf("代理快照已损坏: %w", err))
	}
	if !validSID(snapshot.UserSID) {
		return snapshot, discardSnapshot(path, fmt.Errorf("代理快照缺少用户 SID"))
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
	path := snapshotPath(snapshot.UserSID)
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

func restoreDWord(key registry.Key, name string, value *uint32) error {
	if value == nil {
		err := key.DeleteValue(name)
		if errors.Is(err, registry.ErrNotExist) {
			return nil
		}
		return err
	}
	return key.SetDWordValue(name, *value)
}

func restoreString(key registry.Key, name string, value *string) error {
	if value == nil {
		err := key.DeleteValue(name)
		if errors.Is(err, registry.ErrNotExist) {
			return nil
		}
		return err
	}
	return key.SetStringValue(name, *value)
}

// 不通知的话已运行的 WinINet 客户端不会重读代理设置
func notifySettingsChanged() {
	proc := windows.NewLazySystemDLL("wininet.dll").NewProc("InternetSetOptionW")
	if err := proc.Find(); err != nil {
		return
	}
	proc.Call(0, internetOptionSettingsChanged, 0, 0)
	proc.Call(0, internetOptionRefresh, 0, 0)
}
