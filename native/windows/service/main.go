//go:build windows

package main

import (
	"fmt"
	"net"
	"os"
	"os/signal"

	"golang.org/x/sys/windows/svc"
)

const (
	serviceName        = "ECYCloudService"
	serviceDisplayName = "ECY Cloud 网络服务"
	serviceDescription = "为 ECY Cloud 客户端托管 sing-box 内核、系统代理与 TUN 网卡。"
	serviceVersion     = "1.0.0"
)

func main() {
	command := ""
	if len(os.Args) > 1 {
		command = os.Args[1]
	}

	switch command {
	case "install":
		exit(install())
	case "uninstall":
		exit(uninstall())
	case "debug":
		exit(runConsole())
	case tunCleanupCommand:
		// 由服务自身以子进程方式调用，见 cleanupTunAdapter
		removeTunAdapter()
	default:
		isService, err := svc.IsWindowsService()
		if err != nil {
			exit(fmt.Errorf("判断运行环境失败: %w", err))
		}
		if !isService {
			exit(fmt.Errorf("本程序应由服务控制管理器启动；调试请使用 %s debug", os.Args[0]))
		}
		redirectStderr()
		exit(svc.Run(serviceName, &winService{}))
	}
}

func exit(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		logf("退出: %v", err)
		os.Exit(1)
	}
}

type winService struct{}

func (w *winService) Execute(_ []string, requests <-chan svc.ChangeRequest, changes chan<- svc.Status) (bool, uint32) {
	changes <- svc.Status{State: svc.StartPending}

	srv := newServer()
	// 掉电或强杀会留下快照，必须早于任何 GUI 连接就还原
	if err := srv.proxy.restore(); err != nil {
		logf("启动自检还原系统代理失败: %v", err)
	}

	listener, err := srv.listen()
	if err != nil {
		logf("创建命名管道失败: %v", err)
		return true, 1
	}
	go srv.serve(listener)

	logf("服务已启动，版本 %s", serviceVersion)
	changes <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}

	for req := range requests {
		switch req.Cmd {
		case svc.Interrogate:
			changes <- req.CurrentStatus
		case svc.Stop, svc.Shutdown:
			changes <- svc.Status{State: svc.StopPending}
			listener.Close()
			srv.shutdown()
			logf("服务已停止")
			return false, 0
		}
	}
	return false, 0
}

func runConsole() error {
	srv := newServer()
	if err := srv.proxy.restore(); err != nil {
		logf("启动自检还原系统代理失败: %v", err)
	}

	var listener net.Listener
	listener, err := srv.listen()
	if err != nil {
		return fmt.Errorf("创建命名管道失败: %w", err)
	}
	go srv.serve(listener)

	fmt.Printf("ECY Cloud 服务已在 %s 监听，Ctrl+C 退出\n", pipePath)

	interrupt := make(chan os.Signal, 1)
	signal.Notify(interrupt, os.Interrupt)
	<-interrupt

	listener.Close()
	srv.shutdown()
	return nil
}
