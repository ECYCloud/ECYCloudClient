//go:build darwin && !cgo

package main

import (
	"fmt"
	"net"
	"time"
)

type peer struct {
	pid  int
	user string
	exe  string
}

// 调用方校验依赖 Security 框架；未启用 cgo 的构建只供静态分析，必须拒绝所有调用方
func peerIdentity(*net.UnixConn, time.Time) (*peer, error) {
	return nil, fmt.Errorf("helper 未以 cgo 构建，无法校验调用方")
}

func (*peer) confirm(*net.UnixConn) error {
	return fmt.Errorf("helper 未以 cgo 构建，无法校验调用方")
}

func (*peer) close() {}
