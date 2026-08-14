//go:build linux

package main

import "fmt"

// Linux 的系统代理落在 gsettings 的用户级配置里，客户端自己就能读写，
// 不必经过特权 helper；快照与还原同样由客户端负责。
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
