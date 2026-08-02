import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../service/service_transport.dart';

// Win32 同步 I/O 会阻塞线程，管道读写一律放在临时 isolate 中执行
class NamedPipeClient {
  const NamedPipeClient(this.pipeName);

  final String pipeName;

  Future<Map<String, dynamic>> request(
    String command, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    // 服务靠这个 PID 监听 GUI 进程，GUI 被强杀时代它停内核并还原系统代理
    final String requestLine = jsonEncode(<String, dynamic>{
      'command': command,
      'pid': pid,
      ...payload,
    });

    final String name = pipeName;
    final String responseLine = await Isolate.run(
      () => _transact(name, requestLine),
    );

    final Object? decoded = jsonDecode(responseLine);
    if (decoded is! Map<String, dynamic>) {
      throw PipeException('服务返回了非预期内容');
    }

    if (decoded['ok'] != true) {
      throw PipeException(decoded['error'] as String? ?? '服务处理失败');
    }

    final Object? data = decoded['data'];
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }
}

class PipeException extends ServiceException {
  PipeException(super.message, {this.lastError});

  final int? lastError;

  @override
  bool get serviceUnavailable =>
      lastError == _errorFileNotFound || lastError == _errorPipeBusy;

  @override
  String toString() =>
      lastError == null ? message : '$message（Win32 错误 $lastError）';
}

const int _genericRead = 0x80000000;
const int _genericWrite = 0x40000000;
const int _openExisting = 3;
const int _invalidHandleValue = -1;
const int _errorFileNotFound = 2;
const int _errorPipeBusy = 231;
const int _errorBrokenPipe = 109;
const int _errorMoreData = 234;
const int _readBufferSize = 64 * 1024;
const int _connectTimeoutMs = 5000;

typedef _CreateFileWNative =
    IntPtr Function(
      Pointer<Utf16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      IntPtr,
    );
typedef _CreateFileWDart =
    int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int);

typedef _ReadWriteNative =
    Int32 Function(
      IntPtr,
      Pointer<Uint8>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Void>,
    );
typedef _ReadWriteDart =
    int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>);

String _transact(String pipeName, String requestLine) {
  final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');

  final _CreateFileWDart createFile = kernel32
      .lookupFunction<_CreateFileWNative, _CreateFileWDart>('CreateFileW');
  final _ReadWriteDart readFile = kernel32
      .lookupFunction<_ReadWriteNative, _ReadWriteDart>('ReadFile');
  final _ReadWriteDart writeFile = kernel32
      .lookupFunction<_ReadWriteNative, _ReadWriteDart>('WriteFile');
  final int Function(int) closeHandle = kernel32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  final int Function() getLastError = kernel32
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  final int Function(Pointer<Utf16>, int) waitNamedPipe = kernel32
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, int)
      >('WaitNamedPipeW');

  final Pointer<Utf16> name = pipeName.toNativeUtf16();
  int handle = _invalidHandleValue;

  try {
    handle = createFile(
      name,
      _genericRead | _genericWrite,
      0,
      nullptr,
      _openExisting,
      0,
      0,
    );

    if (handle == _invalidHandleValue && getLastError() == _errorPipeBusy) {
      waitNamedPipe(name, _connectTimeoutMs);
      handle = createFile(
        name,
        _genericRead | _genericWrite,
        0,
        nullptr,
        _openExisting,
        0,
        0,
      );
    }

    if (handle == _invalidHandleValue) {
      throw PipeException('无法连接后台服务', lastError: getLastError());
    }

    _write(writeFile, getLastError, handle, utf8.encode('$requestLine\n'));
    return _read(readFile, getLastError, handle);
  } finally {
    if (handle != _invalidHandleValue) {
      closeHandle(handle);
    }
    malloc.free(name);
  }
}

void _write(
  _ReadWriteDart writeFile,
  int Function() getLastError,
  int handle,
  List<int> bytes,
) {
  final Pointer<Uint8> buffer = calloc<Uint8>(bytes.length);
  final Pointer<Uint32> written = calloc<Uint32>();

  try {
    buffer.asTypedList(bytes.length).setAll(0, bytes);

    int offset = 0;
    while (offset < bytes.length) {
      final int ok = writeFile(
        handle,
        buffer + offset,
        bytes.length - offset,
        written,
        nullptr,
      );
      if (ok == 0) {
        throw PipeException('向后台服务写入失败', lastError: getLastError());
      }
      offset += written.value;
    }
  } finally {
    calloc.free(buffer);
    calloc.free(written);
  }
}

String _read(_ReadWriteDart readFile, int Function() getLastError, int handle) {
  final Pointer<Uint8> buffer = calloc<Uint8>(_readBufferSize);
  final Pointer<Uint32> read = calloc<Uint32>();
  final BytesBuilder collected = BytesBuilder();

  try {
    while (true) {
      final int ok = readFile(handle, buffer, _readBufferSize, read, nullptr);
      if (ok == 0) {
        final int error = getLastError();
        // 服务应答完毕即关闭连接，EOF 表现为 ERROR_BROKEN_PIPE
        if (error == _errorBrokenPipe) {
          break;
        }
        if (error != _errorMoreData) {
          throw PipeException('读取后台服务响应失败', lastError: error);
        }
      }

      if (read.value == 0) {
        break;
      }

      collected.add(buffer.asTypedList(read.value));
    }

    final Uint8List bytes = collected.takeBytes();
    if (bytes.isEmpty) {
      throw PipeException('后台服务未返回任何内容');
    }
    return utf8.decode(bytes).trim();
  } finally {
    calloc.free(buffer);
    calloc.free(read);
  }
}
