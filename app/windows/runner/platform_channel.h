#ifndef RUNNER_PLATFORM_CHANNEL_H_
#define RUNNER_PLATFORM_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <string>

// 只作窗口标题与托盘提示；标题含版本号，任何跨版本查找都不能靠它匹配
extern const wchar_t kWindowTitle[];

UINT ShowWindowMessageId();

class PlatformChannel {
 public:
  // view 是引擎创建的 FlutterView 子窗口：WM_IME_* 由它接收，输入法关联要挂在它上面
  PlatformChannel(flutter::BinaryMessenger* messenger, HWND window, HWND view);
  ~PlatformChannel();

  PlatformChannel(const PlatformChannel&) = delete;
  PlatformChannel& operator=(const PlatformChannel&) = delete;

  bool HandleWindowMessage(UINT message,
                           WPARAM wparam,
                           LPARAM lparam,
                           LRESULT* result);

 private:
  static LRESULT CALLBACK ViewSubclassProc(HWND hwnd,
                                           UINT message,
                                           WPARAM wparam,
                                           LPARAM lparam,
                                           UINT_PTR subclass_id,
                                           DWORD_PTR ref_data);
  bool HandleViewMessage(UINT message, WPARAM wparam, LPARAM lparam);
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
  std::wstring TrayTip() const;
  void ApplyStatusIcons();
  void EnsureStatusIcons();
  void DestroyTintedIcons();
  HICON DefaultIcon();

  HWND window_ = nullptr;
  HWND view_ = nullptr;
  bool tray_installed_ = false;
  bool close_to_tray_ = true;
  bool connected_ = false;
  bool busy_ = false;
  bool system_proxy_ = false;
  bool tun_ = false;
  bool mode_enabled_ = false;
  std::string route_mode_ = "rule";
  std::wstring status_tip_;
  HICON default_icon_ = nullptr;
  HICON small_icon_ = nullptr;
  HICON big_icon_ = nullptr;
  int icon_tint_ = -1;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_PLATFORM_CHANNEL_H_
