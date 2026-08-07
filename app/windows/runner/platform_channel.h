#ifndef RUNNER_PLATFORM_CHANNEL_H_
#define RUNNER_PLATFORM_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// 单实例逻辑靠标题查找已有窗口，改标题会同时影响 main.cpp 与安装器
extern const wchar_t kWindowTitle[];

UINT ShowWindowMessageId();

class PlatformChannel {
 public:
  // view 是引擎创建的 FlutterView 子窗口：WM_IME_* 由它接收，输入法关联要挂在它上面
  PlatformChannel(flutter::BinaryMessenger* messenger, HWND window, HWND view);
  ~PlatformChannel();

  PlatformChannel(const PlatformChannel&) = delete;
  PlatformChannel& operator=(const PlatformChannel&) = delete;

  // 返回 true 表示消息已处理，调用方不应再走默认处理
  bool HandleWindowMessage(UINT message,
                           WPARAM wparam,
                           LPARAM lparam,
                           LRESULT* result);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool InstallTray();
  void RemoveTray();
  void QuitApp();
  void ShowTrayMenu();
  void RestoreMainWindow();
  void EmitTrayAction(const char* action);
  void SetImeEnabled(bool enabled);

  HWND window_ = nullptr;
  HWND view_ = nullptr;
  bool tray_installed_ = false;
  bool close_to_tray_ = true;
  bool connected_ = false;
  bool busy_ = false;
  bool system_proxy_ = false;
  bool tun_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_PLATFORM_CHANNEL_H_
