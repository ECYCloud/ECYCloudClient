//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

const stopTimeout = 20 * time.Second

// 默认服务 DACL 不给交互用户 SERVICE_START，补 RP：能启动，停不了、改不了
const serviceSDDL = "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)" +
	"(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)" +
	"(A;;CCLCSWRPLOCRRC;;;IU)" +
	"(A;;CCLCSWLOCRRC;;;SU)"

func install() (resultErr error) {
	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("定位可执行文件失败: %w", err)
	}

	if err := ensureOwnedDir(filepath.Dir(installDir())); err != nil {
		return err
	}
	if err := ensureOwnedDir(installDir()); err != nil {
		return err
	}
	if err := applyDACL(filepath.Dir(installDir()), installDirSDDL); err != nil {
		return fmt.Errorf("收紧安装目录权限失败，拒绝安装特权服务: %w", err)
	}

	manager, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("连接服务控制管理器失败（需要管理员权限）: %w", err)
	}
	defer manager.Disconnect()

	if existing, err := manager.OpenService(serviceName); err == nil {
		existing.Close()
		return fmt.Errorf("服务 %s 已存在，请先执行 uninstall", serviceName)
	}

	service, err := manager.CreateService(serviceName, exe, mgr.Config{
		DisplayName:      serviceDisplayName,
		Description:      serviceDescription,
		StartType:        mgr.StartAutomatic,
		DelayedAutoStart: true,
	}, "run")
	if err != nil {
		return fmt.Errorf("创建服务失败: %w", err)
	}
	defer service.Close()
	defer func() {
		if resultErr == nil {
			return
		}
		if err := stopService(service); err != nil {
			resultErr = errors.Join(resultErr, fmt.Errorf("清理未完成安装时停止服务失败: %w", err))
			return
		}
		if err := service.Delete(); err != nil {
			resultErr = errors.Join(resultErr, fmt.Errorf("清理未完成安装时删除服务失败: %w", err))
		}
	}()

	recovery := []mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 60 * time.Second},
	}
	if err := service.SetRecoveryActions(recovery, uint32((24 * time.Hour).Seconds())); err != nil {
		return fmt.Errorf("配置失败恢复策略失败: %w", err)
	}

	if err := allowInteractiveStart(service); err != nil {
		return err
	}

	if err := service.Start("run"); err != nil {
		return fmt.Errorf("启动服务失败: %w", err)
	}
	deadline := time.Now().Add(stopTimeout)
	for {
		status, err := service.Query()
		if err != nil {
			return fmt.Errorf("查询新服务状态失败: %w", err)
		}
		if status.State == svc.Running {
			break
		}
		if status.State == svc.Stopped || time.Now().After(deadline) {
			return fmt.Errorf("新服务未能正常运行，状态 %d，错误码 %d", status.State, status.Win32ExitCode)
		}
		time.Sleep(100 * time.Millisecond)
	}

	fmt.Printf("服务 %s 安装并启动完成\n", serviceName)
	return nil
}

func allowInteractiveStart(service *mgr.Service) error {
	sd, err := windows.SecurityDescriptorFromString(serviceSDDL)
	if err != nil {
		return fmt.Errorf("解析服务 DACL 失败: %w", err)
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return fmt.Errorf("读取服务 DACL 失败: %w", err)
	}

	if err := windows.SetSecurityInfo(
		service.Handle,
		windows.SE_SERVICE,
		windows.DACL_SECURITY_INFORMATION,
		nil, nil, dacl, nil,
	); err != nil {
		return fmt.Errorf("设置服务 DACL 失败: %w", err)
	}
	return nil
}

func uninstall() error {
	manager, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("连接服务控制管理器失败（需要管理员权限）: %w", err)
	}
	defer manager.Disconnect()

	service, err := manager.OpenService(serviceName)
	if err != nil {
		return fmt.Errorf("服务 %s 未安装", serviceName)
	}
	defer service.Close()

	if err := stopService(service); err != nil {
		return err
	}
	if err := service.Delete(); err != nil {
		return fmt.Errorf("删除服务失败: %w", err)
	}

	fmt.Printf("服务 %s 已卸载\n", serviceName)
	return nil
}

// 必须等到真正停止：shutdown 里要还原系统代理并销毁网卡，提前删服务会来不及
func stopService(service *mgr.Service) error {
	status, err := service.Query()
	if err != nil {
		return fmt.Errorf("查询服务状态失败: %w", err)
	}
	if status.State == svc.Stopped {
		return nil
	}

	if status, err = service.Control(svc.Stop); err != nil {
		return fmt.Errorf("停止服务失败: %w", err)
	}

	deadline := time.Now().Add(stopTimeout)
	for status.State != svc.Stopped {
		if time.Now().After(deadline) {
			return fmt.Errorf("服务在 %s 内未停止", stopTimeout)
		}
		time.Sleep(300 * time.Millisecond)
		if status, err = service.Query(); err != nil {
			return fmt.Errorf("查询服务状态失败: %w", err)
		}
	}
	return nil
}
