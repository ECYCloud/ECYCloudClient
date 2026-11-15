#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "gpu_watchdog.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  if (!CreateEngine(project_)) {
    return false;
  }

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

bool FlutterWindow::CreateEngine(const flutter::DartProject& project) {
  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    flutter_controller_ = nullptr;
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  gpu_watchdog::Start(flutter_controller_->engine(), GetHandle());
  HWND view = flutter_controller_->view()->GetNativeWindow();
  if (platform_channel_) {
    platform_channel_->Attach(flutter_controller_->engine()->messenger(), view);
  } else {
    platform_channel_ = std::make_unique<PlatformChannel>(
        flutter_controller_->engine()->messenger(), GetHandle(), view);
  }
  SetChildContent(view);

  // 显卡在首帧前就丢失时窗口还没显示过，重建后仍要等新引擎首帧再显示
  if (!shown_) {
    flutter_controller_->engine()->SetNextFrameCallback([&]() {
      shown_ = true;
      this->Show();
    });
  }
  return true;
}

// 新引擎是新的 Dart 实例，靠启动时的 adoptRunningKernel 认回仍在运行的内核；内核只回报
// TUN 开关，系统代理模式下分不出接管与待机，所以由旧实例最后上报的托盘状态告知
void FlutterWindow::RebuildEngine() {
  gpu_watchdog::Stop();
  const bool takeover = platform_channel_->connected();
  platform_channel_->Detach();
  flutter_controller_ = nullptr;

  flutter::DartProject project = project_;
  std::vector<std::string> arguments = project_.dart_entrypoint_arguments();
  if (takeover) {
    arguments.emplace_back("--resume-takeover");
  }
  project.set_dart_entrypoint_arguments(std::move(arguments));
  if (!CreateEngine(project)) {
    gpu_watchdog::Relaunch();
    return;
  }
  flutter_controller_->ForceRedraw();
}

void FlutterWindow::OnDestroy() {
  gpu_watchdog::Stop();
  platform_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_CLOSE || message == WM_EXITSIZEMOVE) {
    Win32Window::PersistSize(hwnd);
  }

  if (message == gpu_watchdog::kRebuildMessage && flutter_controller_) {
    RebuildEngine();
    return 0;
  }

  // 必须早于 Flutter 处理，否则 WM_CLOSE 会被默认关窗逻辑吃掉
  if (platform_channel_) {
    LRESULT result = 0;
    if (platform_channel_->HandleWindowMessage(message, wparam, lparam,
                                               &result)) {
      return result;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }

    if (message == WM_FONTCHANGE) {
      flutter_controller_->engine()->ReloadSystemFonts();
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
