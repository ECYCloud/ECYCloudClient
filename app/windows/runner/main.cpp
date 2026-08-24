#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "gpu_watchdog.h"
#include "platform_channel.h"
#include "utils.h"

namespace {

// 普通用户无 SeCreateGlobalPrivilege，不能用 Global\ 前缀
constexpr const wchar_t kInstanceMutexName[] = L"Local\\ECYCloud.SingleInstance";

// 不能按窗口标题 FindWindow：标题含版本号，覆盖安装后新旧实例标题不一致
void ActivateExistingInstance() {
  ::PostMessageW(HWND_BROADCAST, ShowWindowMessageId(), 0, 0);
}

Win32Window::Point CenteredOrigin(const Win32Window::Size& size) {
  POINT primary_point{0, 0};
  HMONITOR monitor =
      ::MonitorFromPoint(primary_point, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO info{sizeof(info)};
  ::GetMonitorInfo(monitor, &info);

  const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  const int work_width =
      static_cast<int>((info.rcWork.right - info.rcWork.left) / scale);
  const int work_height =
      static_cast<int>((info.rcWork.bottom - info.rcWork.top) / scale);
  const int x = static_cast<int>(info.rcWork.left / scale) +
                std::max(0, (work_width - static_cast<int>(size.width)) / 2);
  const int y = static_cast<int>(info.rcWork.top / scale) +
                std::max(0, (work_height - static_cast<int>(size.height)) / 2);
  return Win32Window::Point(x, y);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE instance_mutex = ::CreateMutexW(nullptr, TRUE, kInstanceMutexName);
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ActivateExistingInstance();
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }
  gpu_watchdog::HoldInstanceMutex(instance_mutex);

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Size size = Win32Window::RestoredSize();
  Win32Window::Point origin = CenteredOrigin(size);
  if (!window.Create(kWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  gpu_watchdog::CloseInstanceMutex();
  return EXIT_SUCCESS;
}
