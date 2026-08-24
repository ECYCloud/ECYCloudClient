import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/logger.dart';
import '../../core/safe_url.dart';
import '../../domain/config/local_template.dart';
import '../../domain/platform/platform_service.dart';
import 'service_pipe.dart';

class WindowsPlatformService implements PlatformService {
  WindowsPlatformService() : _pipe = ServicePipe.production() {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const String _source = 'platform';
  static const MethodChannel _channel = MethodChannel('ecycloud/platform');

  static const Map<String, TrayAction> _trayActions = <String, TrayAction>{
    'connect': TrayAction.connect,
    'disconnect': TrayAction.disconnect,
    'system_proxy': TrayAction.toggleSystemProxy,
    'tun': TrayAction.toggleTun,
    'mode_rule': TrayAction.modeRule,
    'mode_global': TrayAction.modeGlobal,
    'mode_direct': TrayAction.modeDirect,
  };

  final ServicePipe _pipe;
  final StreamController<TrayAction> _trayActionController =
      StreamController<TrayAction>.broadcast();

  @override
  String get platformId => 'windows';

  @override
  bool get supportsTun => true;

  @override
  bool get requiresTun => false;

  @override
  bool get supportsSystemProxy => true;

  @override
  bool get supportsTray => true;

  @override
  bool get supportsLaunchAtLogin => true;

  @override
  bool get supportsPerAppProxy => false;

  @override
  bool get isTelevision => false;

  @override
  bool get supportsPayScheme => false;

  @override
  String get tunInterfaceName => LocalTemplateOptions.defaultTunInterfaceName;

  @override
  Future<void> initialize() async {
    await _channel.invokeMethod<void>('tray.install');

    final SystemProxyState state = await systemProxyState();
    if (state.snapshotPresent) {
      Logger.instance.warn(_source, '检测到上次未还原的系统代理，已自动还原');
      await restoreSystemProxy();
    }
  }

  @override
  Future<void> setSystemProxy({
    required int port,
    required List<String> bypass,
  }) async {
    await _pipe.request('proxy.set', <String, dynamic>{
      'port': port,
      'bypass': bypass,
    });
  }

  @override
  Future<void> restoreSystemProxy() async {
    await _pipe.request('proxy.restore');
  }

  @override
  Future<SystemProxyState> systemProxyState() async {
    final Map<String, dynamic> result = await _pipe.request('proxy.state');
    return SystemProxyState(
      enabled: result['enabled'] == true,
      server: result['server'] as String? ?? '',
      snapshotPresent: result['snapshot_present'] == true,
    );
  }

  @override
  Future<bool> launchAtLoginEnabled() async =>
      await _channel.invokeMethod<bool>('autostart.get') ?? false;

  @override
  Future<void> setLaunchAtLogin({required bool enabled}) async {
    await _channel.invokeMethod<void>('autostart.set', <String, dynamic>{
      'enabled': enabled,
    });
  }

  @override
  Future<void> setCloseToTray({required bool enabled}) async {
    await _channel.invokeMethod<void>('tray.closeToTray', <String, dynamic>{
      'enabled': enabled,
    });
  }

  @override
  Future<void> setImeEnabled({required bool enabled}) async {
    await _channel.invokeMethod<void>('ime.setEnabled', <String, dynamic>{
      'enabled': enabled,
    });
  }

  @override
  Stream<TrayAction> get trayActions => _trayActionController.stream;

  @override
  Future<void> setTrayState(TrayState state) async {
    await _channel.invokeMethod<void>('tray.state', state.toJson());
  }

  @override
  Future<void> setWindowDark({
    required bool dark,
    int caption = 0,
    int text = 0,
  }) async {
    await _channel.invokeMethod<void>('window.setDark', <String, dynamic>{
      'dark': dark,
      'caption': caption,
      'text': text,
    });
  }

  @override
  Future<String> deviceName() async => Platform.localHostname;

  @override
  Future<({String model, String os})> deviceProfile() async {
    String model = _currentVersionValue('ProductName');
    // 注册表 ProductName 在 Windows 11 上仍写着 Windows 10，只能按内部版本号纠正
    if ((int.tryParse(_currentVersionValue('CurrentBuildNumber')) ?? 0) >=
        22000) {
      model = model.replaceFirst('Windows 10', 'Windows 11');
    }
    return (model: model, os: _currentVersionValue('DisplayVersion'));
  }

  @override
  Future<List<InstalledApp>> installedApps() async => const <InstalledApp>[];

  @override
  Future<bool> runInstaller(String path) async =>
      await _channel.invokeMethod<bool>('installer.run', <String, dynamic>{
        'path': path,
      }) ??
      false;

  @override
  Future<bool> openUrl(String url) {
    if (!SafeUrl.canOpen(url)) {
      return Future<bool>.value(false);
    }
    return Isolate.run(() => _shellOpen(url));
  }

  @override
  Future<bool> openDirectory(String path) {
    if (path.isEmpty) {
      return Future<bool>.value(false);
    }
    return Isolate.run(() => _shellOpen(path));
  }

  @override
  Future<String> protectSecret(String name, String plaintext) =>
      Future<String>.value(_dpapiProtect(name, plaintext));

  @override
  Future<String?> unprotectSecret(String name, String blob) =>
      Future<String?>.value(_dpapiUnprotect(name, blob));

  @override
  Future<void> deleteSecret(String name) async {}

  @override
  Future<void> dispose() async {
    await _channel.invokeMethod<void>('tray.remove');
    await _trayActionController.close();
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method == 'clipboard.paste') {
      final BuildContext? context = primaryFocus?.context;
      if (context != null && context.mounted) {
        Actions.maybeInvoke<PasteTextIntent>(
          context,
          const PasteTextIntent(SelectionChangedCause.keyboard),
        );
      }
      return;
    }
    if (call.method != 'tray.action') {
      return;
    }
    final TrayAction? action = _trayActions[call.arguments as String?];
    if (action == null || _trayActionController.isClosed) {
      return;
    }
    _trayActionController.add(action);
  }
}

const int _swShowNormal = 1;

typedef _ShellExecuteWNative =
    IntPtr Function(
      IntPtr,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Int32,
    );
typedef _ShellExecuteWDart =
    int Function(
      int,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Pointer<Utf16>,
      int,
    );

/// 只能走 ShellExecuteW：经由 cmd 打开时，URL 查询串里的 & 会被当成命令分隔符，
/// 链接在第一个 & 处被截断
bool _shellOpen(String url) {
  final Pointer<Utf16> operation = 'open'.toNativeUtf16();
  final Pointer<Utf16> file = url.toNativeUtf16();

  try {
    // ShellExecuteW 的返回值大于 32 才算启动成功，小于等于 32 的都是错误码
    return DynamicLibrary.open(
          'shell32.dll',
        ).lookupFunction<_ShellExecuteWNative, _ShellExecuteWDart>(
          'ShellExecuteW',
        )(0, operation, file, nullptr, nullptr, _swShowNormal) >
        32;
  } finally {
    malloc.free(operation);
    malloc.free(file);
  }
}

const int _hkeyLocalMachine = 0x80000002;
const int _rrfRtRegSz = 0x00000002;
const String _currentVersionKey =
    r'SOFTWARE\Microsoft\Windows NT\CurrentVersion';

typedef _RegGetValueWNative =
    Int32 Function(
      IntPtr,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Uint16>,
      Pointer<Uint32>,
    );
typedef _RegGetValueWDart =
    int Function(
      int,
      Pointer<Utf16>,
      Pointer<Utf16>,
      int,
      Pointer<Uint32>,
      Pointer<Uint16>,
      Pointer<Uint32>,
    );

String _currentVersionValue(String name) {
  const int capacity = 256;
  final Pointer<Utf16> subKey = _currentVersionKey.toNativeUtf16();
  final Pointer<Utf16> value = name.toNativeUtf16();
  final Pointer<Uint16> buffer = calloc<Uint16>(capacity);
  final Pointer<Uint32> size = calloc<Uint32>();

  try {
    size.value = capacity * 2;
    final int status = DynamicLibrary.open(
      'advapi32.dll',
    ).lookupFunction<_RegGetValueWNative, _RegGetValueWDart>('RegGetValueW')(
      _hkeyLocalMachine,
      subKey,
      value,
      _rrfRtRegSz,
      nullptr,
      buffer,
      size,
    );
    if (status != 0) {
      return '';
    }
    return buffer.cast<Utf16>().toDartString();
  } finally {
    malloc.free(subKey);
    malloc.free(value);
    calloc.free(buffer);
    calloc.free(size);
  }
}

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _CryptProtectNative =
    Int32 Function(
      Pointer<_DataBlob>,
      Pointer<Utf16>,
      Pointer<_DataBlob>,
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<_DataBlob>,
    );
typedef _CryptProtectDart =
    int Function(
      Pointer<_DataBlob>,
      Pointer<Utf16>,
      Pointer<_DataBlob>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<_DataBlob>,
    );

typedef _CryptUnprotectNative =
    Int32 Function(
      Pointer<_DataBlob>,
      Pointer<Pointer<Utf16>>,
      Pointer<_DataBlob>,
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<_DataBlob>,
    );
typedef _CryptUnprotectDart =
    int Function(
      Pointer<_DataBlob>,
      Pointer<Pointer<Utf16>>,
      Pointer<_DataBlob>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<_DataBlob>,
    );

// 禁止弹出 DPAPI 确认框，否则登录会被系统对话框卡住
const int _cryptProtectUiForbidden = 0x1;

String _dpapiEntropyFor(String name) => name == 'remembered_password'
    ? 'ECYCloud.remembered_login'
    : 'ECYCloud.$name';

String _dpapiProtect(String name, String plaintext) => base64Encode(
  _dpapiTransform(
    utf8.encode(plaintext),
    entropy: _dpapiEntropyFor(name),
    protect: true,
  ),
);

String? _dpapiUnprotect(String name, String blob) {
  final Uint8List raw;
  try {
    raw = base64Decode(blob);
  } on FormatException {
    return null;
  }
  if (raw.isEmpty) {
    return null;
  }
  try {
    return utf8.decode(
      _dpapiTransform(
        raw,
        entropy: _dpapiEntropyFor(name),
        protect: false,
      ),
    );
  } on PlatformServiceException {
    return null;
  } on FormatException {
    return null;
  }
}

Uint8List _dpapiTransform(
  List<int> input, {
  required String entropy,
  required bool protect,
}) {
  final Uint8List entropyBytes = Uint8List.fromList(utf8.encode(entropy));
  final Pointer<_DataBlob> dataIn = calloc<_DataBlob>();
  final Pointer<_DataBlob> dataOut = calloc<_DataBlob>();
  final Pointer<_DataBlob> entropyBlob = calloc<_DataBlob>();
  final Pointer<Uint8> inputPtr = input.isEmpty
      ? nullptr
      : calloc<Uint8>(input.length);
  final Pointer<Uint8> entropyPtr = calloc<Uint8>(entropyBytes.length);

  try {
    if (input.isNotEmpty) {
      inputPtr.asTypedList(input.length).setAll(0, input);
    }
    dataIn.ref
      ..cbData = input.length
      ..pbData = inputPtr;
    entropyPtr.asTypedList(entropyBytes.length).setAll(0, entropyBytes);
    entropyBlob.ref
      ..cbData = entropyBytes.length
      ..pbData = entropyPtr;

    final DynamicLibrary crypt32 = DynamicLibrary.open('crypt32.dll');
    final int ok = protect
        ? crypt32
              .lookupFunction<_CryptProtectNative, _CryptProtectDart>(
                'CryptProtectData',
              )(
                dataIn,
                nullptr,
                entropyBlob,
                nullptr,
                nullptr,
                _cryptProtectUiForbidden,
                dataOut,
              )
        : crypt32
              .lookupFunction<_CryptUnprotectNative, _CryptUnprotectDart>(
                'CryptUnprotectData',
              )(
                dataIn,
                nullptr,
                entropyBlob,
                nullptr,
                nullptr,
                _cryptProtectUiForbidden,
                dataOut,
              );
    if (ok == 0) {
      throw PlatformServiceException('无法保护凭据');
    }

    final Uint8List output = Uint8List.fromList(
      dataOut.ref.pbData.asTypedList(dataOut.ref.cbData),
    );
    DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('LocalFree')(dataOut.ref.pbData.cast());
    return output;
  } finally {
    if (inputPtr != nullptr) {
      calloc.free(inputPtr);
    }
    calloc.free(entropyPtr);
    calloc.free(dataIn);
    calloc.free(dataOut);
    calloc.free(entropyBlob);
  }
}
