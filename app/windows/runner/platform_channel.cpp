#include "platform_channel.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <string>

#include "resource.h"

// 用 \u 转义而不是直接写汉字：源码字符集依赖构建配置，转义在哪都不会串码。
// 版本号取编译期注入的 FLUTTER_VERSION（由 flutter build --build-name 给出），
// 与安装包版本同源，不另存一份。
#define WIDEN_(x) L##x
#define WIDEN(x) WIDEN_(x)
const wchar_t kWindowTitle[] =
    L"ECY Cloud \u7F51\u7EDC\u52A9\u624B " WIDEN(FLUTTER_VERSION);

namespace {

constexpr UINT kTrayCallbackMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;
constexpr UINT kMenuCommandShow = 40001;
constexpr UINT kMenuCommandExit = 40002;
constexpr UINT kMenuCommandConnect = 40003;
constexpr UINT kMenuCommandDisconnect = 40004;
constexpr UINT kMenuCommandSystemProxy = 40005;
constexpr UINT kMenuCommandTun = 40006;

constexpr const wchar_t kRunKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr const wchar_t kRunValue[] = L"ECY Cloud";

bool ReadBool(const flutter::EncodableMap& arguments, const char* key) {
  auto entry = arguments.find(flutter::EncodableValue(key));
  return entry != arguments.end() &&
         std::holds_alternative<bool>(entry->second) &&
         std::get<bool>(entry->second);
}

// Win32 弹出菜单由 uxtheme 绘制，不受 Flutter 主题影响，只能切进程级的
// 深色模式。相关导出没有头文件声明，只能按序号取：
// 1809 的 135 号是 AllowDarkModeForApp(BOOL)，1903 起换成
// SetPreferredAppMode(枚举)，两者调用约定一致，按内部版本号区分传参即可。
// 取不到导出就保持系统默认外观，不影响其余功能。
enum PreferredAppMode { kAppModeDefault = 0, kAppModeForceLight = 3, kAppModeForceDark = 2 };

void ApplyMenuTheme(bool dark) {
  using SetPreferredAppModeProc = int(WINAPI*)(int);
  using FlushMenuThemesProc = void(WINAPI*)();

  static bool resolved = false;
  static SetPreferredAppModeProc set_mode = nullptr;
  static FlushMenuThemesProc flush = nullptr;
  static bool legacy_bool_arg = false;

  if (!resolved) {
    resolved = true;
    // GetVersionEx 受清单兼容性垫片影响会谎报版本，取 ntdll 的真实版本号；
    // 该导出无头文件声明，只能动态取
    using RtlGetNtVersionNumbersProc = void(WINAPI*)(DWORD*, DWORD*, DWORD*);
    DWORD major = 0, minor = 0, build = 0;
    if (HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll")) {
      if (auto version = reinterpret_cast<RtlGetNtVersionNumbersProc>(
              ::GetProcAddress(ntdll, "RtlGetNtVersionNumbers"))) {
        version(&major, &minor, &build);
        build &= ~0xF0000000;
      }
    }
    if (major >= 10 && build >= 17763) {
      // 用 GetModuleHandle：uxtheme 已由 Flutter 的窗口初始化加载，不额外持有引用
      if (HMODULE uxtheme = ::GetModuleHandleW(L"uxtheme.dll")) {
        set_mode = reinterpret_cast<SetPreferredAppModeProc>(
            ::GetProcAddress(uxtheme, MAKEINTRESOURCEA(135)));
        flush = reinterpret_cast<FlushMenuThemesProc>(
            ::GetProcAddress(uxtheme, MAKEINTRESOURCEA(136)));
        legacy_bool_arg = build < 18362;
      }
    }
  }

  if (set_mode == nullptr) {
    return;
  }

  if (legacy_bool_arg) {
    set_mode(dark ? TRUE : FALSE);
  } else {
    set_mode(dark ? kAppModeForceDark : kAppModeForceLight);
  }
  if (flush != nullptr) {
    flush();
  }
}

std::wstring ExecutablePath() {
  wchar_t buffer[MAX_PATH] = {};
  DWORD length = ::GetModuleFileNameW(nullptr, buffer, MAX_PATH);
  return std::wstring(buffer, length);
}

bool AutostartEnabled() {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_QUERY_VALUE, &key) !=
      ERROR_SUCCESS) {
    return false;
  }
  LSTATUS status = ::RegQueryValueExW(key, kRunValue, nullptr, nullptr, nullptr,
                                      nullptr);
  ::RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

bool SetAutostart(bool enabled) {
  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0,
                        KEY_SET_VALUE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) {
    return false;
  }

  LSTATUS status = ERROR_SUCCESS;
  if (enabled) {
    std::wstring command = L"\"" + ExecutablePath() + L"\"";
    status = ::RegSetValueExW(
        key, kRunValue, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    status = ::RegDeleteValueW(key, kRunValue);
    if (status == ERROR_FILE_NOT_FOUND) {
      status = ERROR_SUCCESS;
    }
  }
  ::RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

}  // namespace

UINT ShowWindowMessageId() {
  static const UINT id = ::RegisterWindowMessageW(L"ECYCloud.ShowWindow");
  return id;
}

namespace {

// Explorer 重启（崩溃恢复、清理图标缓存等）会丢掉所有托盘图标，
// 并向各顶层窗口广播这条消息，收到后必须自行重新添加
UINT TaskbarCreatedMessageId() {
  static const UINT id = ::RegisterWindowMessageW(L"TaskbarCreated");
  return id;
}

}  // namespace

PlatformChannel::PlatformChannel(flutter::BinaryMessenger* messenger,
                                 HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "ecycloud/platform",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

PlatformChannel::~PlatformChannel() {
  RemoveTray();
}

void PlatformChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "tray.install") {
    if (!InstallTray()) {
      result->Error("tray", "创建托盘图标失败");
      return;
    }
    result->Success();
    return;
  }

  if (method == "tray.remove") {
    RemoveTray();
    result->Success();
    return;
  }

  if (method == "tray.closeToTray") {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error("argument", "缺少参数");
      return;
    }
    auto entry = arguments->find(flutter::EncodableValue("enabled"));
    if (entry == arguments->end() ||
        !std::holds_alternative<bool>(entry->second)) {
      result->Error("argument", "缺少 enabled");
      return;
    }
    close_to_tray_ = std::get<bool>(entry->second);
    result->Success();
    return;
  }

  if (method == "tray.state") {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error("argument", "缺少参数");
      return;
    }
    connected_ = ReadBool(*arguments, "connected");
    busy_ = ReadBool(*arguments, "busy");
    system_proxy_ = ReadBool(*arguments, "system_proxy");
    tun_ = ReadBool(*arguments, "tun");
    ApplyMenuTheme(ReadBool(*arguments, "dark"));
    result->Success();
    return;
  }

  if (method == "autostart.get") {
    result->Success(flutter::EncodableValue(AutostartEnabled()));
    return;
  }

  if (method == "autostart.set") {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error("argument", "缺少参数");
      return;
    }
    auto entry = arguments->find(flutter::EncodableValue("enabled"));
    if (entry == arguments->end() ||
        !std::holds_alternative<bool>(entry->second)) {
      result->Error("argument", "缺少 enabled");
      return;
    }
    if (!SetAutostart(std::get<bool>(entry->second))) {
      result->Error("autostart", "写入开机自启项失败");
      return;
    }
    result->Success();
    return;
  }

  result->NotImplemented();
}

bool PlatformChannel::InstallTray() {
  if (tray_installed_) {
    return true;
  }

  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kTrayIconId;
  data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  data.uCallbackMessage = kTrayCallbackMessage;
  data.hIcon = ::LoadIconW(::GetModuleHandleW(nullptr),
                           MAKEINTRESOURCEW(IDI_APP_ICON));
  wcsncpy_s(data.szTip, kWindowTitle, _TRUNCATE);

  tray_installed_ = ::Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
  return tray_installed_;
}

void PlatformChannel::RemoveTray() {
  if (!tray_installed_) {
    return;
  }

  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kTrayIconId;
  ::Shell_NotifyIconW(NIM_DELETE, &data);
  tray_installed_ = false;
}

void PlatformChannel::ShowTrayMenu() {
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }

  if (busy_) {
    ::AppendMenuW(menu, MF_STRING, kMenuCommandDisconnect, L"取消连接");
  } else if (connected_) {
    ::AppendMenuW(menu, MF_STRING, kMenuCommandDisconnect, L"断开连接");
  } else {
    ::AppendMenuW(menu, MF_STRING, kMenuCommandConnect, L"连接");
  }
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING | (system_proxy_ ? MF_CHECKED : MF_UNCHECKED),
                kMenuCommandSystemProxy, L"系统代理");
  ::AppendMenuW(menu, MF_STRING | (tun_ ? MF_CHECKED : MF_UNCHECKED),
                kMenuCommandTun, L"TUN 模式");
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kMenuCommandShow, L"显示主界面");
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kMenuCommandExit, L"退出");

  POINT cursor = {};
  ::GetCursorPos(&cursor);
  // 不置前台会导致菜单在点击别处时不消失
  ::SetForegroundWindow(window_);
  ::TrackPopupMenu(menu, TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, window_,
                   nullptr);
  ::DestroyMenu(menu);
}

void PlatformChannel::RestoreMainWindow() {
  ::ShowWindow(window_, ::IsIconic(window_) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(window_);
}

// 托盘只上报动作，连不连、开不开由 Dart 侧状态机决定
void PlatformChannel::EmitTrayAction(const char* action) {
  channel_->InvokeMethod(
      "tray.action",
      std::make_unique<flutter::EncodableValue>(std::string(action)));
}

bool PlatformChannel::HandleWindowMessage(UINT message,
                                          WPARAM wparam,
                                          LPARAM lparam,
                                          LRESULT* result) {
  if (message == ShowWindowMessageId()) {
    RestoreMainWindow();
    *result = 0;
    return true;
  }

  if (message == TaskbarCreatedMessageId()) {
    // 图标已随旧 Explorer 一起消失，先把状态清掉才能重新添加
    if (tray_installed_) {
      tray_installed_ = false;
      InstallTray();
    }
    return false;
  }

  switch (message) {
    case kTrayCallbackMessage:
      if (LOWORD(lparam) == WM_LBUTTONDBLCLK ||
          LOWORD(lparam) == WM_LBUTTONUP) {
        RestoreMainWindow();
      } else if (LOWORD(lparam) == WM_RBUTTONUP) {
        ShowTrayMenu();
      }
      *result = 0;
      return true;

    case WM_COMMAND:
      switch (LOWORD(wparam)) {
        case kMenuCommandShow:
          RestoreMainWindow();
          break;
        case kMenuCommandExit:
          RemoveTray();
          ::DestroyWindow(window_);
          break;
        case kMenuCommandConnect:
          EmitTrayAction("connect");
          break;
        case kMenuCommandDisconnect:
          EmitTrayAction("disconnect");
          break;
        case kMenuCommandSystemProxy:
          EmitTrayAction("system_proxy");
          break;
        case kMenuCommandTun:
          EmitTrayAction("tun");
          break;
        default:
          return false;
      }
      *result = 0;
      return true;

    case WM_CLOSE:
      // 托盘不可用时不能吞掉关闭，否则窗口再也关不掉
      if (close_to_tray_ && tray_installed_) {
        ::ShowWindow(window_, SW_HIDE);
        *result = 0;
        return true;
      }
      return false;

    default:
      return false;
  }
}
