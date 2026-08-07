#ifndef RUNNER_GPU_WATCHDOG_H_
#define RUNNER_GPU_WATCHDOG_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

// 显卡驱动更新、TDR 超时或休眠唤醒会让 ANGLE 的 D3D 设备永久丢失。Flutter 引擎
// 没有恢复路径（flutter#111151），界面就此空白，只能重开客户端。这里在 ANGLE 用
// 的同一块适配器上留一个哨兵设备与之同生共死，一旦丢失就自动重启进程。
//
// 不在进程内重建 FlutterViewController：那要求 ANGLE 的析构跑完 eglTerminate 才能
// 清掉进程级的 EGLDisplay 单例，而它会在已死的 D3D 对象上访问越界，唯一已知的绕法
// 是用向量化异常处理器吞掉 flutter_windows.dll 里的 ACCESS_VIOLATION，不可接受。
namespace gpu_watchdog {

// 单实例互斥体转交给本模块持有：重启前必须先关掉，新进程才不会把自己当重复实例
void HoldInstanceMutex(HANDLE mutex);
void CloseInstanceMutex();

// 取不到适配器或建不出哨兵设备时静默放弃，不影响正常运行
void Start(flutter::FlutterEngine* engine);
void Stop();

}  // namespace gpu_watchdog

#endif  // RUNNER_GPU_WATCHDOG_H_
