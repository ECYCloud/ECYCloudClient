#ifndef RUNNER_GPU_WATCHDOG_H_
#define RUNNER_GPU_WATCHDOG_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

// Flutter 引擎对 ANGLE D3D 设备丢失没有恢复路径（flutter#111151），只能重启进程
namespace gpu_watchdog {

// 重启前必须先关掉单实例互斥体，否则新进程会把自己当重复实例
void HoldInstanceMutex(HANDLE mutex);
void CloseInstanceMutex();

void Start(flutter::FlutterEngine* engine);
void Stop();

}  // namespace gpu_watchdog

#endif  // RUNNER_GPU_WATCHDOG_H_
