#include "gpu_watchdog.h"

#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>

#include <atomic>
#include <string>
#include <thread>

namespace gpu_watchdog {

namespace {

using Microsoft::WRL::ComPtr;

constexpr DWORD kPollIntervalMs = 2000;

std::atomic<HANDLE> g_instance_mutex{nullptr};
std::thread g_thread;
HANDLE g_stop_event = nullptr;

void Relaunch() {
  CloseInstanceMutex();

  wchar_t path[MAX_PATH]{};
  if (::GetModuleFileNameW(nullptr, path, MAX_PATH) != 0) {
    // 原样沿用命令行：开机自启是带参数拉起的，重启后行为要一致
    std::wstring command_line = ::GetCommandLineW();
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION created{};
    if (::CreateProcessW(path, command_line.data(), nullptr, nullptr, FALSE, 0,
                         nullptr, nullptr, &startup, &created)) {
      ::CloseHandle(created.hProcess);
      ::CloseHandle(created.hThread);
    }
  }

  // 渲染已死，消息循环未必还转得动，走不了正常退出路径；
  // 内核与系统代理由特权服务在本进程消失后收尾
  ::ExitProcess(EXIT_SUCCESS);
}

void Poll(ComPtr<ID3D11Device> sentinel) {
  while (::WaitForSingleObject(g_stop_event, kPollIntervalMs) == WAIT_TIMEOUT) {
    if (sentinel->GetDeviceRemovedReason() != S_OK) {
      Relaunch();
    }
  }
}

}  // namespace

void HoldInstanceMutex(HANDLE mutex) { g_instance_mutex.store(mutex); }

void CloseInstanceMutex() {
  HANDLE mutex = g_instance_mutex.exchange(nullptr);
  if (mutex != nullptr) {
    // 只关句柄不 ReleaseMutex：所有权在主线程，看门狗线程放不掉；
    // 句柄全关后内核对象即销毁，名字随之释放，够新进程用了
    ::CloseHandle(mutex);
  }
}

void Start(flutter::FlutterEngine* engine) {
  ComPtr<IDXGIAdapter> adapter;
  if (!engine->GetGraphicsAdapter(adapter.GetAddressOf()) || !adapter) {
    return;
  }

  // 哨兵与 ANGLE 的设备同源，GPU 重置后一起变成 DEVICE_REMOVED 且不再翻回来。
  // 不能改用「每轮新建临时设备」探测：适配器百毫秒内就恢复，新设备总能建成
  ComPtr<ID3D11Device> sentinel;
  if (FAILED(::D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN,
                                 nullptr, 0, nullptr, 0, D3D11_SDK_VERSION,
                                 &sentinel, nullptr, nullptr))) {
    return;
  }

  g_stop_event = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (g_stop_event == nullptr) {
    return;
  }
  g_thread = std::thread(Poll, sentinel);
}

void Stop() {
  if (!g_thread.joinable()) {
    return;
  }
  ::SetEvent(g_stop_event);
  g_thread.join();
  ::CloseHandle(g_stop_event);
  g_stop_event = nullptr;
}

}  // namespace gpu_watchdog
