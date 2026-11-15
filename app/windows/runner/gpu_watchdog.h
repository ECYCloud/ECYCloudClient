#ifndef RUNNER_GPU_WATCHDOG_H_
#define RUNNER_GPU_WATCHDOG_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

// Flutter 引擎对 ANGLE D3D 设备丢失没有恢复路径（flutter#111151），只能销毁重建引擎
namespace gpu_watchdog {

// 显卡丢失时投递给主窗口，由窗口线程重建引擎；WM_APP + 1 已被托盘回调占用
inline constexpr UINT kRebuildMessage = WM_APP + 2;

// 普通用户无 SeCreateGlobalPrivilege，不能用 Global\ 前缀。
inline constexpr wchar_t kInstanceMutexName[] = L"Local\\ECYCloud.SingleInstance";

// 重启前必须先关掉单实例互斥体，否则新进程会把自己当重复实例
void HoldInstanceMutex(HANDLE mutex);
void CloseInstanceMutex();

void Start(flutter::FlutterEngine* engine, HWND window);
void Stop();

// 重建引擎失败时的退路：拉起新进程接替当前进程
void Relaunch();

}  // namespace gpu_watchdog

#endif  // RUNNER_GPU_WATCHDOG_H_
