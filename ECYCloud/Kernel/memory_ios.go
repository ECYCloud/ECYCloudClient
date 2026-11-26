//go:build ios

package kernel

// iOS 15 起系统给包隧道扩展 50 MiB，超过即结束进程
const defaultTunnelMemoryLimit = 50 * 1024 * 1024
