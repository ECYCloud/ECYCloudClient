import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

enum WindowsServiceState {
  missing,
  stopped,
  starting,
  stopping,
  running,
  denied,
  unknown,
}

class ServiceProbe {
  const ServiceProbe(this.state, {this.detail});

  final WindowsServiceState state;
  final String? detail;

  bool get running => state == WindowsServiceState.running;

  String get label => switch (state) {
    WindowsServiceState.missing => '未安装',
    WindowsServiceState.stopped => '已停止',
    WindowsServiceState.starting => '正在启动',
    WindowsServiceState.stopping => '正在停止',
    WindowsServiceState.running => '正在运行',
    WindowsServiceState.denied => '无权查询',
    WindowsServiceState.unknown => '状态未知',
  };
}

/// SCM 失败恢复窗口内管道不存在；安装时 SERVICE_START 已授给交互用户（serviceSDDL）。
class ServiceControl {
  const ServiceControl(this.serviceName);

  final String serviceName;

  static const Duration _pollInterval = Duration(milliseconds: 250);

  Future<ServiceProbe> probe() {
    final String name = serviceName;
    return Isolate.run(() => _probe(name));
  }

  Future<ServiceProbe> ensureRunning({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    ServiceProbe probed = await probe();
    if (probed.running || probed.state == WindowsServiceState.missing) {
      return probed;
    }

    if (probed.state == WindowsServiceState.stopped) {
      final String? failure = await _start();
      if (failure != null) {
        return ServiceProbe(WindowsServiceState.stopped, detail: failure);
      }
    }

    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_pollInterval);
      probed = await probe();
      if (probed.running || probed.state == WindowsServiceState.missing) {
        return probed;
      }
      // SCM 的失败恢复计时器还没到点，服务会短暂停在 stopped
      if (probed.state == WindowsServiceState.stopped) {
        await _start();
      }
    }
    return probed;
  }

  Future<String?> _start() {
    final String name = serviceName;
    return Isolate.run(() => _startService(name));
  }
}

const int _scManagerConnect = 0x0001;
const int _serviceQueryStatus = 0x0004;
const int _serviceStart = 0x0010;

const int _stateStopped = 1;
const int _stateStartPending = 2;
const int _stateStopPending = 3;
const int _stateRunning = 4;

const int _errorAccessDenied = 5;
const int _errorServiceDoesNotExist = 1060;
const int _errorServiceAlreadyRunning = 1056;

// SERVICE_STATUS 是 7 个 DWORD，只用到 dwCurrentState（第二个）
const int _serviceStatusDwords = 7;
const int _currentStateIndex = 1;

typedef _OpenSCManagerNative =
    IntPtr Function(Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _OpenSCManagerDart = int Function(Pointer<Utf16>, Pointer<Utf16>, int);

typedef _OpenServiceNative = IntPtr Function(IntPtr, Pointer<Utf16>, Uint32);
typedef _OpenServiceDart = int Function(int, Pointer<Utf16>, int);

typedef _QueryStatusNative = Int32 Function(IntPtr, Pointer<Uint32>);
typedef _QueryStatusDart = int Function(int, Pointer<Uint32>);

typedef _StartServiceNative =
    Int32 Function(IntPtr, Uint32, Pointer<Pointer<Utf16>>);
typedef _StartServiceDart = int Function(int, int, Pointer<Pointer<Utf16>>);

typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);

class _Scm {
  _Scm()
    : _advapi = DynamicLibrary.open('advapi32.dll'),
      _kernel32 = DynamicLibrary.open('kernel32.dll');

  final DynamicLibrary _advapi;
  final DynamicLibrary _kernel32;

  late final _OpenSCManagerDart openManager = _advapi
      .lookupFunction<_OpenSCManagerNative, _OpenSCManagerDart>(
        'OpenSCManagerW',
      );
  late final _OpenServiceDart openService = _advapi
      .lookupFunction<_OpenServiceNative, _OpenServiceDart>('OpenServiceW');
  late final _QueryStatusDart queryStatus = _advapi
      .lookupFunction<_QueryStatusNative, _QueryStatusDart>(
        'QueryServiceStatus',
      );
  late final _StartServiceDart startService = _advapi
      .lookupFunction<_StartServiceNative, _StartServiceDart>('StartServiceW');
  late final _CloseHandleDart closeServiceHandle = _advapi
      .lookupFunction<_CloseHandleNative, _CloseHandleDart>(
        'CloseServiceHandle',
      );
  late final int Function() lastError = _kernel32
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
}

ServiceProbe _probe(String serviceName) {
  final _Scm scm = _Scm();
  final Pointer<Utf16> name = serviceName.toNativeUtf16();
  final Pointer<Uint32> status = calloc<Uint32>(_serviceStatusDwords);
  int manager = 0;
  int service = 0;

  try {
    manager = scm.openManager(nullptr, nullptr, _scManagerConnect);
    if (manager == 0) {
      return ServiceProbe(
        WindowsServiceState.unknown,
        detail: '无法连接服务控制管理器（Win32 错误 ${scm.lastError()}）',
      );
    }

    service = scm.openService(manager, name, _serviceQueryStatus);
    if (service == 0) {
      final int error = scm.lastError();
      return switch (error) {
        _errorServiceDoesNotExist => const ServiceProbe(
          WindowsServiceState.missing,
        ),
        _errorAccessDenied => const ServiceProbe(WindowsServiceState.denied),
        _ => ServiceProbe(
          WindowsServiceState.unknown,
          detail: '打开服务失败（Win32 错误 $error）',
        ),
      };
    }

    if (scm.queryStatus(service, status) == 0) {
      return ServiceProbe(
        WindowsServiceState.unknown,
        detail: '查询服务状态失败（Win32 错误 ${scm.lastError()}）',
      );
    }

    return ServiceProbe(switch (status[_currentStateIndex]) {
      _stateRunning => WindowsServiceState.running,
      _stateStartPending => WindowsServiceState.starting,
      _stateStopPending => WindowsServiceState.stopping,
      _stateStopped => WindowsServiceState.stopped,
      _ => WindowsServiceState.unknown,
    });
  } finally {
    if (service != 0) {
      scm.closeServiceHandle(service);
    }
    if (manager != 0) {
      scm.closeServiceHandle(manager);
    }
    calloc.free(status);
    malloc.free(name);
  }
}

String? _startService(String serviceName) {
  final _Scm scm = _Scm();
  final Pointer<Utf16> name = serviceName.toNativeUtf16();
  int manager = 0;
  int service = 0;

  try {
    manager = scm.openManager(nullptr, nullptr, _scManagerConnect);
    if (manager == 0) {
      return '无法连接服务控制管理器（Win32 错误 ${scm.lastError()}）';
    }

    service = scm.openService(manager, name, _serviceStart);
    if (service == 0) {
      final int error = scm.lastError();
      return error == _errorAccessDenied
          ? '当前账户无权启动该服务，请以管理员身份启动 ECYCloudService'
          : '打开服务失败（Win32 错误 $error）';
    }

    if (scm.startService(service, 0, nullptr) == 0) {
      final int error = scm.lastError();
      return error == _errorServiceAlreadyRunning
          ? null
          : '启动服务失败（Win32 错误 $error）';
    }
    return null;
  } finally {
    if (service != 0) {
      scm.closeServiceHandle(service);
    }
    if (manager != 0) {
      scm.closeServiceHandle(manager);
    }
    malloc.free(name);
  }
}
