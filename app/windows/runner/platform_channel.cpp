#include "platform_channel.h"

#include <commctrl.h>
#include <flutter/standard_method_codec.h>
#include <imm.h>
#include <shellapi.h>

#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

#include "resource.h"
#include "utils.h"

// 用 \u 转义而不是直接写汉字：源码字符集依赖构建配置，转义在哪都不会串码。
// 版本号取编译期注入的 ECYCLOUD_DISPLAY_VERSION（见 runner/CMakeLists.txt），
// 与 Dart 侧 AppConfig.appVersion 同源，Pre 通道带前缀。
#define WIDEN_(x) L##x
#define WIDEN(x) WIDEN_(x)
const wchar_t kWindowTitle[] =
    L"ECY Cloud " WIDEN(ECYCLOUD_DISPLAY_VERSION);

namespace {

constexpr UINT kTrayCallbackMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;
constexpr UINT kMenuCommandShow = 40001;
constexpr UINT kMenuCommandExit = 40002;
constexpr UINT kMenuCommandConnect = 40003;
constexpr UINT kMenuCommandDisconnect = 40004;
constexpr UINT kMenuCommandSystemProxy = 40005;
constexpr UINT kMenuCommandTun = 40006;
constexpr UINT kMenuCommandModeRule = 40007;
constexpr UINT kMenuCommandModeGlobal = 40008;
constexpr UINT kMenuCommandModeDirect = 40009;

constexpr const wchar_t kRunKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr const wchar_t kRunValue[] = L"ECY Cloud";

std::wstring WideFromUtf8(const std::string& text);

bool ReadBool(const flutter::EncodableMap& arguments, const char* key) {
  auto entry = arguments.find(flutter::EncodableValue(key));
  return entry != arguments.end() &&
         std::holds_alternative<bool>(entry->second) &&
         std::get<bool>(entry->second);
}

std::wstring g_label_connect = L"\u8fde\u63a5";
std::wstring g_label_disconnect = L"\u65ad\u5f00\u8fde\u63a5";
std::wstring g_label_cancel = L"\u53d6\u6d88\u8fde\u63a5";
std::wstring g_label_system_proxy = L"\u7cfb\u7edf\u4ee3\u7406";
std::wstring g_label_tun = L"TUN \u6a21\u5f0f";
std::wstring g_label_rule = L"\u89c4\u5219";
std::wstring g_label_global = L"\u5168\u5c40";
std::wstring g_label_direct = L"\u76f4\u8fde";
std::wstring g_label_show = L"\u663e\u793a\u4e3b\u754c\u9762";
std::wstring g_label_quit = L"\u9000\u51fa";

std::string ReadUtf8(const flutter::EncodableMap& arguments,
                     const char* key,
                     const std::string& fallback) {
  auto entry = arguments.find(flutter::EncodableValue(key));
  if (entry == arguments.end() ||
      !std::holds_alternative<std::string>(entry->second)) {
    return fallback;
  }
  const std::string& text = std::get<std::string>(entry->second);
  return text.empty() ? fallback : text;
}

void AppendRadioItem(HMENU menu,
                     UINT id,
                     const std::wstring& label,
                     bool checked,
                     bool enabled) {
  MENUITEMINFOW info = {};
  info.cbSize = sizeof(info);
  info.fMask = MIIM_FTYPE | MIIM_ID | MIIM_STRING | MIIM_STATE;
  info.fType = MFT_STRING | MFT_RADIOCHECK;
  info.wID = id;
  info.dwTypeData = const_cast<LPWSTR>(label.c_str());
  info.cch = static_cast<UINT>(label.size());
  info.fState = (checked ? MFS_CHECKED : 0) | (enabled ? 0 : MFS_GRAYED);
  ::InsertMenuItemW(menu, static_cast<UINT>(::GetMenuItemCount(menu)), TRUE,
                    &info);
}

void RgbToHsl(float r, float g, float b, float* h, float* s, float* l) {
  const float max = std::max({r, g, b});
  const float min = std::min({r, g, b});
  *l = (max + min) / 2.f;
  if (max == min) {
    *h = 0;
    *s = 0;
    return;
  }
  const float d = max - min;
  *s = *l > 0.5f ? d / (2.f - max - min) : d / (max + min);
  if (max == r) {
    *h = (g - b) / d + (g < b ? 6.f : 0);
  } else if (max == g) {
    *h = (b - r) / d + 2.f;
  } else {
    *h = (r - g) / d + 4.f;
  }
  *h *= 60.f;
}

float HueToChannel(float p, float q, float t) {
  if (t < 0) {
    t += 1.f;
  }
  if (t > 1.f) {
    t -= 1.f;
  }
  if (t < 1.f / 6.f) {
    return p + (q - p) * 6.f * t;
  }
  if (t < 0.5f) {
    return q;
  }
  if (t < 2.f / 3.f) {
    return p + (q - p) * (2.f / 3.f - t) * 6.f;
  }
  return p;
}

void HslToRgb(float h, float s, float l, float* r, float* g, float* b) {
  if (s == 0) {
    *r = *g = *b = l;
    return;
  }
  const float q = l < 0.5f ? l * (1.f + s) : l + s - l * s;
  const float p = 2.f * l - q;
  const float hk = h / 360.f;
  *r = HueToChannel(p, q, hk + 1.f / 3.f);
  *g = HueToChannel(p, q, hk);
  *b = HueToChannel(p, q, hk - 1.f / 3.f);
}

HICON CreateTintedIcon(HICON source, float target_hue, int size) {
  if (source == nullptr || size <= 0) {
    return nullptr;
  }
  HICON sized = static_cast<HICON>(
      ::CopyImage(source, IMAGE_ICON, size, size, 0));
  if (sized == nullptr) {
    return nullptr;
  }

  ICONINFO info = {};
  if (!::GetIconInfo(sized, &info) || info.hbmColor == nullptr) {
    ::DestroyIcon(sized);
    return nullptr;
  }

  BITMAP bm = {};
  ::GetObject(info.hbmColor, sizeof(bm), &bm);
  const int width = bm.bmWidth;
  const int height = bm.bmHeight;
  if (width <= 0 || height <= 0) {
    ::DeleteObject(info.hbmColor);
    if (info.hbmMask != nullptr) {
      ::DeleteObject(info.hbmMask);
    }
    ::DestroyIcon(sized);
    return nullptr;
  }

  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  std::vector<UINT32> pixels(static_cast<size_t>(width) * height);
  HDC dc = ::GetDC(nullptr);
  const int copied = ::GetDIBits(dc, info.hbmColor, 0, height, pixels.data(),
                                 &bmi, DIB_RGB_COLORS);
  if (copied != height) {
    ::ReleaseDC(nullptr, dc);
    ::DeleteObject(info.hbmColor);
    if (info.hbmMask != nullptr) {
      ::DeleteObject(info.hbmMask);
    }
    ::DestroyIcon(sized);
    return nullptr;
  }

  for (UINT32& pixel : pixels) {
    const BYTE a = static_cast<BYTE>((pixel >> 24) & 0xFF);
    if (a == 0) {
      continue;
    }
    const float r = static_cast<float>((pixel >> 16) & 0xFF) / 255.f;
    const float g = static_cast<float>((pixel >> 8) & 0xFF) / 255.f;
    const float b = static_cast<float>(pixel & 0xFF) / 255.f;
    float h = 0;
    float s = 0;
    float l = 0;
    RgbToHsl(r, g, b, &h, &s, &l);
    if (s <= 0.12f || h < 170.f || h > 270.f) {
      continue;
    }
    float nr = 0;
    float ng = 0;
    float nb = 0;
    HslToRgb(target_hue, s, l, &nr, &ng, &nb);
    pixel = (static_cast<UINT32>(a) << 24) |
            (static_cast<UINT32>(nr * 255.f + 0.5f) << 16) |
            (static_cast<UINT32>(ng * 255.f + 0.5f) << 8) |
            static_cast<UINT32>(nb * 255.f + 0.5f);
  }

  void* bits = nullptr;
  HBITMAP color =
      ::CreateDIBSection(dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (color == nullptr || bits == nullptr) {
    ::ReleaseDC(nullptr, dc);
    ::DeleteObject(info.hbmColor);
    if (info.hbmMask != nullptr) {
      ::DeleteObject(info.hbmMask);
    }
    ::DestroyIcon(sized);
    return nullptr;
  }
  std::memcpy(bits, pixels.data(), pixels.size() * sizeof(UINT32));

  HBITMAP mask = ::CreateBitmap(width, height, 1, 1, nullptr);
  ICONINFO out = {};
  out.fIcon = TRUE;
  out.hbmMask = mask;
  out.hbmColor = color;
  HICON result = ::CreateIconIndirect(&out);

  ::DeleteObject(color);
  if (mask != nullptr) {
    ::DeleteObject(mask);
  }
  ::DeleteObject(info.hbmColor);
  if (info.hbmMask != nullptr) {
    ::DeleteObject(info.hbmMask);
  }
  ::ReleaseDC(nullptr, dc);
  ::DestroyIcon(sized);
  return result;
}

std::wstring ReadLabel(const flutter::EncodableMap& arguments,
                       const char* key,
                       const std::wstring& fallback) {
  auto entry = arguments.find(flutter::EncodableValue(key));
  if (entry == arguments.end() ||
      !std::holds_alternative<std::string>(entry->second)) {
    return fallback;
  }
  const std::string& text = std::get<std::string>(entry->second);
  return text.empty() ? fallback : WideFromUtf8(text);
}

// 托盘菜单由 uxtheme 画，不受 Flutter 主题影响。135/136 号导出无头文件：
// 1809 是 AllowDarkModeForApp(BOOL)，1903 起是 SetPreferredAppMode(枚举)
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

// 系统没有「默认等宽字体」这种设置项，只能问设备装了哪些：取系统枚举到的第一个
// 矢量等宽字族。点阵字体（Terminal / Fixedsys）放大后全是锯齿，排除掉
int CALLBACK PickFixedPitch(const LOGFONTW* font,
                            const TEXTMETRICW*,
                            DWORD type,
                            LPARAM param) {
  if ((type & TRUETYPE_FONTTYPE) == 0 ||
      (font->lfPitchAndFamily & 0x03) != FIXED_PITCH ||
      font->lfFaceName[0] == L'@') {  // @ 开头是竖排版本，不是独立字族
    return 1;
  }
  *reinterpret_cast<std::wstring*>(param) = font->lfFaceName;
  return 0;
}

std::wstring SystemFixedPitchFamily() {
  std::wstring face;
  HDC dc = ::GetDC(nullptr);
  if (dc == nullptr) {
    return face;
  }
  LOGFONTW query{};
  query.lfCharSet = DEFAULT_CHARSET;
  ::EnumFontFamiliesExW(dc, &query, PickFixedPitch,
                        reinterpret_cast<LPARAM>(&face), 0);
  ::ReleaseDC(nullptr, dc);
  return face;
}

std::wstring WideFromUtf8(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  int size = ::MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                   static_cast<int>(text.size()), nullptr, 0);
  std::wstring wide(size, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                        wide.data(), size);
  return wide;
}

// 安装包清单要求管理员权限，CreateProcess 会直接失败（ERROR_ELEVATION_REQUIRED），
// 只能由 ShellExecuteEx 弹 UAC；返回 false 即用户拒绝提权
bool RunElevated(const std::wstring& path) {
  SHELLEXECUTEINFOW info = {};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_NOASYNC;
  info.lpVerb = L"runas";
  info.lpFile = path.c_str();
  info.nShow = SW_SHOWNORMAL;
  return ::ShellExecuteExW(&info) != FALSE;
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

// 关窗口只是缩到托盘，安装/卸载程序无法用 WM_CLOSE 让客户端腾出被占用的 exe 与 dll；
// 由它广播这条消息触发与托盘「退出」相同的收尾（摘图标后销毁窗口）
UINT QuitMessageId() {
  static const UINT id = ::RegisterWindowMessageW(L"ECYCloud.Quit");
  return id;
}

}  // namespace

PlatformChannel::PlatformChannel(flutter::BinaryMessenger* messenger,
                                 HWND window,
                                 HWND view)
    : window_(window), view_(view) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "ecycloud/platform",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
  if (view_ != nullptr) {
    ::SetWindowSubclass(view_, ViewSubclassProc, 1,
                        reinterpret_cast<DWORD_PTR>(this));
  }
}

PlatformChannel::~PlatformChannel() {
  if (view_ != nullptr) {
    ::RemoveWindowSubclass(view_, ViewSubclassProc, 1);
  }
  RemoveTray();
  DestroyTintedIcons();
}

HICON PlatformChannel::DefaultIcon() {
  if (default_icon_ == nullptr) {
    default_icon_ = ::LoadIconW(::GetModuleHandleW(nullptr),
                                MAKEINTRESOURCEW(IDI_APP_ICON));
  }
  return default_icon_;
}

void PlatformChannel::DestroyTintedIcons() {
  if (small_icon_ != nullptr && small_icon_ != default_icon_) {
    ::DestroyIcon(small_icon_);
  }
  if (big_icon_ != nullptr && big_icon_ != default_icon_ &&
      big_icon_ != small_icon_) {
    ::DestroyIcon(big_icon_);
  }
  small_icon_ = nullptr;
  big_icon_ = nullptr;
  icon_tint_ = -1;
}

void PlatformChannel::EnsureStatusIcons() {
  const int want = tun_ ? 2 : (system_proxy_ ? 1 : 0);
  if (want == icon_tint_ && small_icon_ != nullptr && big_icon_ != nullptr) {
    return;
  }

  DestroyTintedIcons();
  HICON source = DefaultIcon();
  if (want == 0) {
    small_icon_ = source;
    big_icon_ = source;
    icon_tint_ = want;
    return;
  }

  const float hue = want == 2 ? 150.f : 42.f;
  small_icon_ = CreateTintedIcon(source, hue, ::GetSystemMetrics(SM_CXSMICON));
  big_icon_ = CreateTintedIcon(source, hue, ::GetSystemMetrics(SM_CXICON));
  if (small_icon_ == nullptr) {
    small_icon_ = source;
  }
  if (big_icon_ == nullptr) {
    big_icon_ = source;
  }
  icon_tint_ = want;
}

std::wstring PlatformChannel::TrayTip() const {
  std::wstring tip = kWindowTitle;
  if (!status_tip_.empty()) {
    tip += L'\n';
    tip += status_tip_;
  }
  return tip;
}

void PlatformChannel::ApplyStatusIcons() {
  EnsureStatusIcons();
  ::SendMessageW(window_, WM_SETICON, ICON_SMALL,
                 reinterpret_cast<LPARAM>(small_icon_));
  ::SendMessageW(window_, WM_SETICON, ICON_BIG,
                 reinterpret_cast<LPARAM>(big_icon_));
  if (!tray_installed_) {
    return;
  }
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kTrayIconId;
  data.uFlags = NIF_ICON | NIF_TIP;
  data.hIcon = small_icon_;
  wcsncpy_s(data.szTip, TrayTip().c_str(), _TRUNCATE);
  ::Shell_NotifyIconW(NIM_MODIFY, &data);
}

void PlatformChannel::SetImeEnabled(bool enabled) {
  if (view_ == nullptr) {
    return;
  }
  if (!enabled) {
    HIMC himc = ::ImmGetContext(view_);
    if (himc != nullptr) {
      ::ImmNotifyIME(himc, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
      ::ImmReleaseContext(view_, himc);
    }
  }
  ::ImmAssociateContextEx(view_, nullptr, enabled ? IACE_DEFAULT : 0);
}

// Win11 剪贴板历史用 SendInput 合成 Ctrl+V，扫描码为 0。引擎把这类按键映射坏，
// 焦点字段收不到 PasteTextIntent，只能在壳层拦下来交给 Dart 走同一条粘贴动作。
bool PlatformChannel::HandleViewMessage(UINT message,
                                        WPARAM wparam,
                                        LPARAM lparam) {
  if (message != WM_KEYDOWN || wparam != 'V') {
    return false;
  }
  if ((::GetKeyState(VK_CONTROL) & 0x8000) == 0) {
    return false;
  }
  if (((lparam >> 16) & 0xFF) != 0) {
    return false;
  }
  channel_->InvokeMethod("clipboard.paste", nullptr);
  return true;
}

LRESULT CALLBACK PlatformChannel::ViewSubclassProc(HWND hwnd,
                                                   UINT message,
                                                   WPARAM wparam,
                                                   LPARAM lparam,
                                                   UINT_PTR subclass_id,
                                                   DWORD_PTR ref_data) {
  auto* self = reinterpret_cast<PlatformChannel*>(ref_data);
  if (self != nullptr && self->HandleViewMessage(message, wparam, lparam)) {
    return 0;
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

void PlatformChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "tray.install") {
    // 加不上不算失败：TaskbarCreated 会重试。报错会让 Dart 侧 initialize() 抛出，
    // 连同一个 try 里的 syncPlatformSettings() 一起跳过，整个会话的平台设置不同步
    InstallTray();
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
    mode_enabled_ = ReadBool(*arguments, "mode_enabled");
    route_mode_ = ReadUtf8(*arguments, "route_mode", route_mode_);
    status_tip_ = ReadLabel(*arguments, "status_tip", status_tip_);
    g_label_connect = ReadLabel(*arguments, "label_connect", g_label_connect);
    g_label_disconnect =
        ReadLabel(*arguments, "label_disconnect", g_label_disconnect);
    g_label_cancel = ReadLabel(*arguments, "label_cancel", g_label_cancel);
    g_label_system_proxy =
        ReadLabel(*arguments, "label_system_proxy", g_label_system_proxy);
    g_label_tun = ReadLabel(*arguments, "label_tun", g_label_tun);
    g_label_rule = ReadLabel(*arguments, "label_rule", g_label_rule);
    g_label_global = ReadLabel(*arguments, "label_global", g_label_global);
    g_label_direct = ReadLabel(*arguments, "label_direct", g_label_direct);
    g_label_show = ReadLabel(*arguments, "label_show", g_label_show);
    g_label_quit = ReadLabel(*arguments, "label_quit", g_label_quit);
    ApplyMenuTheme(ReadBool(*arguments, "dark"));
    ApplyStatusIcons();
    result->Success();
    return;
  }

  if (method == "ime.setEnabled") {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error("argument", "缺少参数");
      return;
    }
    SetImeEnabled(ReadBool(*arguments, "enabled"));
    result->Success();
    return;
  }

  if (method == "installer.run") {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error("argument", "缺少参数");
      return;
    }
    auto entry = arguments->find(flutter::EncodableValue("path"));
    if (entry == arguments->end() ||
        !std::holds_alternative<std::string>(entry->second)) {
      result->Error("argument", "缺少 path");
      return;
    }
    result->Success(flutter::EncodableValue(
        RunElevated(WideFromUtf8(std::get<std::string>(entry->second)))));
    return;
  }

  // 字体不在客户端写死：界面字体取系统自己的消息框字体（中文系统是雅黑 UI、英文
  // 系统是 Segoe UI，用户在个性化里换过就是换过的那个），与其它 Win32 程序同源；
  // 等宽字体取设备上枚举到的第一个
  if (method == "ui.fonts") {
    NONCLIENTMETRICSW metrics{};
    metrics.cbSize = sizeof(metrics);
    if (!::SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(metrics),
                                 &metrics, 0)) {
      result->Error("ui.fonts", "读取系统界面字体失败");
      return;
    }
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("ui"),
         flutter::EncodableValue(
             Utf8FromUtf16(metrics.lfMessageFont.lfFaceName))},
        {flutter::EncodableValue("mono"),
         flutter::EncodableValue(
             Utf8FromUtf16(SystemFixedPitchFamily().c_str()))},
    }));
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

  // Shell_NotifyIcon 在通知区未就绪时会堵几秒消息循环；窗口要等第一帧才 Show，先探测再交给 TaskbarCreated
  if (::FindWindowW(L"Shell_TrayWnd", nullptr) == nullptr) {
    return false;
  }

  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kTrayIconId;
  data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  data.uCallbackMessage = kTrayCallbackMessage;
  EnsureStatusIcons();
  data.hIcon = small_icon_;
  wcsncpy_s(data.szTip, TrayTip().c_str(), _TRUNCATE);

  tray_installed_ = ::Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
  ::SendMessageW(window_, WM_SETICON, ICON_SMALL,
                 reinterpret_cast<LPARAM>(small_icon_));
  ::SendMessageW(window_, WM_SETICON, ICON_BIG,
                 reinterpret_cast<LPARAM>(big_icon_));
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
  DestroyTintedIcons();
  HICON icon = DefaultIcon();
  ::SendMessageW(window_, WM_SETICON, ICON_SMALL,
                 reinterpret_cast<LPARAM>(icon));
  ::SendMessageW(window_, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(icon));
}

void PlatformChannel::ShowTrayMenu() {
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }

  if (busy_) {
    ::AppendMenuW(menu, MF_STRING, kMenuCommandDisconnect,
                  g_label_cancel.c_str());
  } else if (connected_) {
    ::AppendMenuW(menu, MF_STRING, kMenuCommandDisconnect,
                  g_label_disconnect.c_str());
  } else {
    ::AppendMenuW(menu, MF_STRING, kMenuCommandConnect, g_label_connect.c_str());
  }
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  const UINT proxy_state = connected_ ? 0 : MF_GRAYED;
  ::AppendMenuW(menu,
                MF_STRING | proxy_state |
                    (system_proxy_ ? MF_CHECKED : MF_UNCHECKED),
                kMenuCommandSystemProxy, g_label_system_proxy.c_str());
  ::AppendMenuW(menu,
                MF_STRING | proxy_state | (tun_ ? MF_CHECKED : MF_UNCHECKED),
                kMenuCommandTun, g_label_tun.c_str());
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  const std::string& mode =
      (route_mode_ == "global" || route_mode_ == "direct") ? route_mode_
                                                          : "rule";
  AppendRadioItem(menu, kMenuCommandModeRule, g_label_rule, mode == "rule",
                  mode_enabled_);
  AppendRadioItem(menu, kMenuCommandModeGlobal, g_label_global,
                  mode == "global", mode_enabled_);
  AppendRadioItem(menu, kMenuCommandModeDirect, g_label_direct,
                  mode == "direct", mode_enabled_);
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kMenuCommandShow, g_label_show.c_str());
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kMenuCommandExit, g_label_quit.c_str());

  POINT cursor = {};
  ::GetCursorPos(&cursor);
  // 不置前台会导致菜单在点击别处时不消失
  ::SetForegroundWindow(window_);
  ::TrackPopupMenu(menu, TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, window_,
                   nullptr);
  ::DestroyMenu(menu);
}

void PlatformChannel::QuitApp() {
  RemoveTray();
  ::DestroyWindow(window_);
}

void PlatformChannel::RestoreMainWindow() {
  ::ShowWindow(window_, ::IsIconic(window_) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(window_);
}

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

  if (message == QuitMessageId()) {
    QuitApp();
    *result = 0;
    return true;
  }

  if (message == TaskbarCreatedMessageId()) {
    // 首次因通知区未就绪而跳过时 tray_installed_ 也是 false，必须无条件重试
    tray_installed_ = false;
    InstallTray();
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
          QuitApp();
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
        case kMenuCommandModeRule:
          EmitTrayAction("mode_rule");
          break;
        case kMenuCommandModeGlobal:
          EmitTrayAction("mode_global");
          break;
        case kMenuCommandModeDirect:
          EmitTrayAction("mode_direct");
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
