#include "gpu_watchdog.h"

#include <d3d11_4.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

#include <atomic>
#include <string>
#include <thread>

namespace gpu_watchdog {

namespace {

using Microsoft::WRL::ComPtr;

std::atomic<HANDLE> g_instance_mutex{nullptr};
std::thread g_thread;
HANDLE g_stop_event = nullptr;

// 必须用新建的工厂枚举：工厂的适配器列表停在它创建的那一刻
bool AdapterPresent(const LUID& luid) {
  ComPtr<IDXGIFactory1> factory;
  if (FAILED(::CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
    return true;
  }
  ComPtr<IDXGIAdapter1> candidate;
  for (UINT i = 0; factory->EnumAdapters1(i, &candidate) != DXGI_ERROR_NOT_FOUND;
       ++i) {
    DXGI_ADAPTER_DESC1 desc{};
    if (SUCCEEDED(candidate->GetDesc1(&desc)) &&
        desc.AdapterLuid.LowPart == luid.LowPart &&
        desc.AdapterLuid.HighPart == luid.HighPart) {
      return true;
    }
  }
  return false;
}

ComPtr<IDXGIFactory7> WatchAdapters(HANDLE event, DWORD* cookie) {
  ComPtr<IDXGIFactory7> factory;
  if (FAILED(::CreateDXGIFactory2(0, IID_PPV_ARGS(&factory))) ||
      FAILED(factory->RegisterAdaptersChangedEvent(event, cookie))) {
    return nullptr;
  }
  return factory;
}

// 哨兵必须与 ANGLE 同一适配器，不能等事件后再新建（适配器会先恢复）。
// 设备已被移除时登记会立即触发事件。
ComPtr<ID3D11Device4> WatchDevice(IDXGIAdapter* adapter, HANDLE event) {
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11Device4> sentinel;
  DWORD cookie = 0;
  if (FAILED(::D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0,
                                 nullptr, 0, D3D11_SDK_VERSION, &device,
                                 nullptr, nullptr)) ||
      FAILED(device.As(&sentinel)) ||
      FAILED(sentinel->RegisterDeviceRemovedEvent(event, &cookie))) {
    return nullptr;
  }
  return sentinel;
}

// 建设备必须在本线程：Start() 仍在 CreateWindow 内，D3D11CreateDevice 同步可达数秒。
// 驱动安装中途重启出来的进程，适配器可能在哨兵建好前又被重启、哨兵建不起来；
// 适配器重启后 LUID 会变，所以适配器列表一变就核对原 LUID 是否还在。
void Poll(ComPtr<IDXGIAdapter> adapter, HWND window) {
  DXGI_ADAPTER_DESC adapter_desc{};
  if (FAILED(adapter->GetDesc(&adapter_desc))) {
    return;
  }
  HANDLE adapters_changed = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
  HANDLE device_removed = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
  HANDLE events[3] = {g_stop_event};
  DWORD event_count = 1;
  DWORD adapters_cookie = 0;
  ComPtr<IDXGIFactory7> notifier;
  if (adapters_changed != nullptr) {
    notifier = WatchAdapters(adapters_changed, &adapters_cookie);
    if (notifier) {
      events[event_count++] = adapters_changed;
    }
  }
  ComPtr<ID3D11Device4> sentinel;
  if (device_removed != nullptr) {
    sentinel = WatchDevice(adapter.Get(), device_removed);
    if (sentinel) {
      events[event_count++] = device_removed;
    }
  }

  // 先登记再核对，登记前已发生的变化由这次核对兜住
  bool lost = !AdapterPresent(adapter_desc.AdapterLuid);
  while (!lost) {
    const DWORD result =
        ::WaitForMultipleObjects(event_count, events, FALSE, INFINITE);
    if (result >= WAIT_OBJECT_0 + event_count) {
      break;
    }
    const HANDLE signaled = events[result - WAIT_OBJECT_0];
    if (signaled == g_stop_event) {
      break;
    }
    lost = signaled == device_removed ||
           !AdapterPresent(adapter_desc.AdapterLuid);
  }
  if (lost) {
    ::PostMessageW(window, kRebuildMessage, 0, 0);
  }

  // 事件句柄必须比登记活得久：设备释放时自动注销，工厂需显式注销
  sentinel.Reset();
  if (notifier) {
    notifier->UnregisterAdaptersChangedEvent(adapters_cookie);
  }
  for (HANDLE event : {adapters_changed, device_removed}) {
    if (event != nullptr) {
      ::CloseHandle(event);
    }
  }
}

}  // namespace

void Relaunch() {
  wchar_t path[MAX_PATH]{};
  const DWORD length = ::GetModuleFileNameW(nullptr, path, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return;
  }

  // 原样沿用命令行：开机自启是带参数拉起的，重启后行为要一致
  std::wstring command_line = ::GetCommandLineW();
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION created{};
  // 新进程必须先挂起，创建成功后才能释放单实例锁，否则启动失败会丢掉当前实例。
  if (!::CreateProcessW(path, command_line.data(), nullptr, nullptr, FALSE,
                        CREATE_SUSPENDED, nullptr, nullptr, &startup, &created)) {
    return;
  }

  CloseInstanceMutex();
  const bool resumed = ::ResumeThread(created.hThread) != static_cast<DWORD>(-1);
  if (!resumed) {
    HoldInstanceMutex(::CreateMutexW(nullptr, TRUE, kInstanceMutexName));
    ::TerminateProcess(created.hProcess, EXIT_FAILURE);
  }
  ::CloseHandle(created.hThread);
  ::CloseHandle(created.hProcess);

  if (resumed) {
    ::ExitProcess(EXIT_SUCCESS);
  }
}

void HoldInstanceMutex(HANDLE mutex) { g_instance_mutex.store(mutex); }

void CloseInstanceMutex() {
  HANDLE mutex = g_instance_mutex.exchange(nullptr);
  if (mutex != nullptr) {
    // 句柄全关后内核对象即销毁，名字随之释放，够新进程用了
    ::CloseHandle(mutex);
  }
}

void Start(flutter::FlutterEngine* engine, HWND window) {
  ComPtr<IDXGIAdapter> adapter;
  if (!engine->GetGraphicsAdapter(adapter.GetAddressOf()) || !adapter) {
    return;
  }

  g_stop_event = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (g_stop_event == nullptr) {
    return;
  }
  g_thread = std::thread(Poll, adapter, window);
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
