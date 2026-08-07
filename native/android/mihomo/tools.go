//go:build tools

// gomobile bind 生成的 Go 侧胶水代码会 import golang.org/x/mobile/bind，
// 依赖必须留在 go.mod 里才能锁版本；本文件不参与实际构建。
package mihomo

import _ "golang.org/x/mobile/bind"
