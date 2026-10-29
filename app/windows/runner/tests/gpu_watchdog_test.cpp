#include <flutter/flutter_engine.h>
#include <windows.h>

#include <cstdio>
#include <cwchar>
#include <string>
#include <vector>

namespace {

struct ExitRequested {};

const HANDLE kMutex = reinterpret_cast<HANDLE>(1);
const HANDLE kProcess = reinterpret_cast<HANDLE>(2);
const HANDLE kThread = reinterpret_cast<HANDLE>(3);
const HANDLE kRestoredMutex = reinterpret_cast<HANDLE>(4);
constexpr wchar_t kPath[] = L"D:\\ECY Cloud\\ECYCloud.exe";
wchar_t test_command_line[] = L"\"D:\\ECY Cloud\\ECYCloud.exe\" --test-argument";
DWORD path_length = static_cast<DWORD>(std::wcslen(kPath));
bool create_succeeds = true;
bool resume_succeeds = true;
bool suspended = false;
bool preserved_command = false;
bool restored_mutex = false;
std::vector<std::string> calls;
int failures = 0;

void Check(bool condition, const char* message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    ++failures;
  }
}

DWORD WINAPI TestGetModuleFileNameW(HMODULE, LPWSTR buffer, DWORD size) {
  wcscpy_s(buffer, size, kPath);
  return path_length;
}

LPWSTR WINAPI TestGetCommandLineW() { return test_command_line; }

BOOL WINAPI TestCreateProcessW(LPCWSTR path, LPWSTR arguments,
                              LPSECURITY_ATTRIBUTES, LPSECURITY_ATTRIBUTES,
                              BOOL inherit, DWORD flags, LPVOID, LPCWSTR,
                              LPSTARTUPINFOW startup,
                              LPPROCESS_INFORMATION created) {
  calls.emplace_back("create");
  suspended = (flags & CREATE_SUSPENDED) != 0;
  preserved_command = std::wcscmp(path, kPath) == 0 &&
                      std::wcscmp(arguments, test_command_line) == 0 && !inherit &&
                      startup->cb == sizeof(*startup);
  if (!create_succeeds) {
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    return FALSE;
  }
  created->hProcess = kProcess;
  created->hThread = kThread;
  return TRUE;
}

BOOL WINAPI TestCloseHandle(HANDLE handle) {
  calls.emplace_back(handle == kMutex ? "close_mutex"
                     : handle == kThread ? "close_thread"
                                         : "close_process");
  return TRUE;
}

DWORD WINAPI TestResumeThread(HANDLE handle) {
  Check(handle == kThread, "恢复新进程的主线程");
  calls.emplace_back("resume");
  return resume_succeeds ? 1 : static_cast<DWORD>(-1);
}

HANDLE WINAPI TestCreateMutexW(LPSECURITY_ATTRIBUTES, BOOL owner, LPCWSTR name) {
  calls.emplace_back("restore_mutex");
  restored_mutex = owner && std::wcscmp(name, L"Local\\ECYCloud.SingleInstance") == 0;
  return kRestoredMutex;
}

BOOL WINAPI TestTerminateProcess(HANDLE handle, UINT code) {
  Check(handle == kProcess && code == EXIT_FAILURE, "只清理未恢复的子进程");
  calls.emplace_back("terminate_child");
  return TRUE;
}

void WINAPI TestExitProcess(UINT code) {
  Check(code == EXIT_SUCCESS, "成功交接后退出旧进程");
  calls.emplace_back("exit");
  throw ExitRequested{};
}

}  // namespace

#define GetModuleFileNameW TestGetModuleFileNameW
#define GetCommandLineW TestGetCommandLineW
#define CreateProcessW TestCreateProcessW
#define CloseHandle TestCloseHandle
#define ResumeThread TestResumeThread
#define CreateMutexW TestCreateMutexW
#define TerminateProcess TestTerminateProcess
#define ExitProcess TestExitProcess
#include "../gpu_watchdog.cpp"
#undef GetModuleFileNameW
#undef GetCommandLineW
#undef CreateProcessW
#undef CloseHandle
#undef ResumeThread
#undef CreateMutexW
#undef TerminateProcess
#undef ExitProcess

int main() {
  for (const DWORD length : {DWORD{0}, DWORD{MAX_PATH}}) {
    path_length = length;
    calls.clear();
    gpu_watchdog::HoldInstanceMutex(kMutex);
    try {
      gpu_watchdog::Relaunch();
    } catch (const ExitRequested&) {
    }
    Check(calls.empty(), "路径读取失败或截断时保留客户端");
    Check(gpu_watchdog::g_instance_mutex.load() == kMutex, "路径失败不释放单实例锁");
  }

  path_length = static_cast<DWORD>(std::wcslen(kPath));
  create_succeeds = false;
  calls.clear();
  gpu_watchdog::HoldInstanceMutex(kMutex);
  try {
    gpu_watchdog::Relaunch();
  } catch (const ExitRequested&) {
  }
  Check(calls == std::vector<std::string>{"create"}, "内存不足导致创建失败时不退出");
  Check(gpu_watchdog::g_instance_mutex.load() == kMutex, "创建失败保留单实例锁");

  create_succeeds = true;
  resume_succeeds = false;
  calls.clear();
  try {
    gpu_watchdog::Relaunch();
  } catch (const ExitRequested&) {
  }
  Check(calls == std::vector<std::string>{"create", "close_mutex", "resume",
                                       "restore_mutex", "terminate_child",
                                       "close_thread", "close_process"},
        "恢复线程失败时清理子进程，保留当前客户端");
  Check(restored_mutex && gpu_watchdog::g_instance_mutex.load() == kRestoredMutex,
        "恢复线程失败后重新取得相同的单实例锁");

  resume_succeeds = true;
  calls.clear();
  gpu_watchdog::HoldInstanceMutex(kMutex);
  try {
    gpu_watchdog::Relaunch();
  } catch (const ExitRequested&) {
  }
  Check(suspended && preserved_command, "保留原始命令行且挂起新进程");
  Check(calls == std::vector<std::string>{"create", "close_mutex", "resume",
                                       "close_thread", "close_process", "exit"},
        "先创建、再释放锁、恢复新进程，最后退出旧进程");
  Check(gpu_watchdog::g_instance_mutex.load() == nullptr, "成功交接后释放单实例锁");
  std::printf("GPU 恢复回归：%d 项断言失败\n", failures);
  return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
