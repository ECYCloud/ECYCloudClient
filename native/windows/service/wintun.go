//go:build windows

package main

import (
	"fmt"
	"os"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

// 必须与 Dart 侧 LocalTemplateOptions.tunInterfaceName 一致
const tunAdapterName = "ECYCloud"

var (
	wintunOnce sync.Once
	wintunDLL  *windows.LazyDLL
	wintunErr  error
)

// 完整性由构建期 checksum 保证，运行期不再算哈希
func loadWintun() (*windows.LazyDLL, error) {
	wintunOnce.Do(func() {
		if _, err := os.Stat(wintunPath()); err != nil {
			wintunErr = fmt.Errorf("wintun.dll 缺失: %s", wintunPath())
			return
		}

		dll := windows.NewLazyDLL(wintunPath())
		if err := dll.Load(); err != nil {
			wintunErr = fmt.Errorf("加载 wintun.dll 失败: %w", err)
			return
		}
		for _, name := range []string{"WintunCreateAdapter", "WintunOpenAdapter", "WintunCloseAdapter"} {
			if err := dll.NewProc(name).Find(); err != nil {
				wintunErr = fmt.Errorf("wintun.dll 缺少导出 %s: %w", name, err)
				return
			}
		}
		wintunDLL = dll
	})
	return wintunDLL, wintunErr
}

func ensureTunReady() (bool, string) {
	if _, err := os.Stat(kernelPath()); err != nil {
		return false, fmt.Sprintf("内核程序缺失: %s", kernelPath())
	}
	if _, err := loadWintun(); err != nil {
		return false, err.Error()
	}
	return true, ""
}

// WintunCloseAdapter 只能移除本进程 WintunCreateAdapter 创建的网卡，
// 所以清理残留必须先探测存在性，再"重新创建后关闭"才能真正删掉同名网卡。
func removeTunAdapter() {
	dll, err := loadWintun()
	if err != nil {
		return
	}

	name, err := windows.UTF16PtrFromString(tunAdapterName)
	if err != nil {
		return
	}

	open := dll.NewProc("WintunOpenAdapter")
	create := dll.NewProc("WintunCreateAdapter")
	closeAdapter := dll.NewProc("WintunCloseAdapter")

	handle, _, _ := open.Call(uintptr(unsafe.Pointer(name)))
	if handle == 0 {
		return
	}
	closeAdapter.Call(handle)

	tunnelType, err := windows.UTF16PtrFromString("Wintun")
	if err != nil {
		return
	}
	handle, _, _ = create.Call(uintptr(unsafe.Pointer(name)), uintptr(unsafe.Pointer(tunnelType)), 0)
	if handle != 0 {
		closeAdapter.Call(handle)
	}
}
