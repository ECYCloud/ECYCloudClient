#include "../flutter_window.h"

#include <cstdio>

void RegisterPlugins(flutter::PluginRegistry*) {}

class TestWindow : public FlutterWindow {
 public:
  explicit TestWindow(const flutter::DartProject& project) : FlutterWindow(project) {}

  void SendFontChange() { MessageHandler(nullptr, WM_FONTCHANGE, 0, 0); }
  void TearDown() { OnDestroy(); }
};

bool SendFontChange(TestWindow* window) {
  __try {
    window->SendFontChange();
    return true;
  } __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION
                  ? EXCEPTION_EXECUTE_HANDLER
                  : EXCEPTION_CONTINUE_SEARCH) {
    return false;
  }
}

int main() {
  flutter::DartProject project(L"data");
  TestWindow window(project);
  const bool before_create = SendFontChange(&window);
  window.TearDown();
  const bool after_destroy = SendFontChange(&window);
  std::printf("引擎创建前的字体广播：%s\n销毁后的字体广播：%s\n",
              before_create ? "通过" : "空指针崩溃",
              after_destroy ? "通过" : "空指针崩溃");
  return before_create && after_destroy ? EXIT_SUCCESS : EXIT_FAILURE;
}
