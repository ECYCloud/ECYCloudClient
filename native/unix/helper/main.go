//go:build darwin || linux

package main

import (
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
)

const (
	helperName    = "ecycloud-helper"
	helperVersion = "1.0.0"
)

func main() {
	command := ""
	if len(os.Args) > 1 {
		command = os.Args[1]
	}

	switch command {
	case "install":
		exit(requireRoot(install))
	case "uninstall":
		exit(requireRoot(uninstall))
	case "run":
		exit(requireRoot(run))
	default:
		exit(fmt.Errorf("用法: %s run|install|uninstall", os.Args[0]))
	}
}

func requireRoot(action func() error) error {
	if os.Geteuid() != 0 {
		return fmt.Errorf("需要以 root 身份运行：sudo %s %s", os.Args[0], os.Args[1])
	}
	return action()
}

func run() error {
	srv := newServer()
	// 掉电或强杀会留下快照，必须早于任何 GUI 连接就还原
	if err := srv.proxy.restore(); err != nil {
		logf("启动自检还原系统代理失败: %v", err)
	}

	listener, err := srv.listen()
	if err != nil {
		return fmt.Errorf("创建套接字失败: %w", err)
	}
	go srv.serve(listener)

	logf("后台服务已启动，版本 %s，监听 %s", helperVersion, socketPath)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	listener.Close()
	srv.shutdown()
	logf("后台服务已停止")
	return nil
}

func exit(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		logf("退出: %v", err)
		os.Exit(1)
	}
}

func trimOutput(out []byte, err error) string {
	if message := strings.TrimSpace(string(out)); message != "" {
		return message
	}
	return err.Error()
}
