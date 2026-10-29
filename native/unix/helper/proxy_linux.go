//go:build linux

package main

import "fmt"

// Linux 系统代理在 gsettings 用户配置里，由客户端读写，不经 helper
type proxyManager struct{}

func newProxyManager() *proxyManager { return &proxyManager{} }

func (p *proxyManager) set(_ int, _ int, _ []string) error {
	return fmt.Errorf("Linux 的系统代理由客户端自行设置")
}

func (p *proxyManager) restore() error { return nil }

type proxyState struct {
	Enabled         bool   `json:"enabled"`
	Server          string `json:"server"`
	SnapshotPresent bool   `json:"snapshot_present"`
}

func (p *proxyManager) state(_ int) (proxyState, error) {
	return proxyState{}, nil
}
