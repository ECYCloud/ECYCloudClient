import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract final class ZoomCursors {
  static MouseCursor _zoomInImpl = SystemMouseCursors.zoomIn;
  static MouseCursor _zoomOutImpl = SystemMouseCursors.zoomOut;

  // 进入时再取当前光标：自定义放大镜在首帧后才造好
  static final MouseCursor zoomIn = _ResolvingCursor(() => _zoomInImpl);
  static final MouseCursor zoomOut = _ResolvingCursor(() => _zoomOutImpl);

  static const MethodChannel _desktop = MethodChannel('ecycloud/platform');

  static Future<void> ensureReady() async {
    if (kIsWeb ||
        !(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return;
    }
    final double dpr = ui.PlatformDispatcher.instance.views.isEmpty
        ? 1.0
        : ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
    const int logical = 32;
    final int size = (logical * dpr).round().clamp(32, 128);
    try {
      _zoomInImpl = await _CustomZoomCursor.create(
        name: 'ecycloud_zoom_in',
        icon: Icons.zoom_in,
        size: size,
        logicalSize: logical,
      );
      _zoomOutImpl = await _CustomZoomCursor.create(
        name: 'ecycloud_zoom_out',
        icon: Icons.zoom_out,
        size: size,
        logicalSize: logical,
      );
    } on Object {
      _zoomInImpl = SystemMouseCursors.zoomIn;
      _zoomOutImpl = SystemMouseCursors.zoomOut;
    }
  }

  // 打开大图时鼠标没动，Flutter 要等下一次指针事件才换光标
  static Future<void> showZoomOut() async {
    final MouseCursorSession session = _zoomOutImpl.createSession(0);
    await session.activate();
    session.dispose();
  }
}

class _ResolvingCursor extends MouseCursor {
  const _ResolvingCursor(this._resolve);

  final ValueGetter<MouseCursor> _resolve;

  @override
  String get debugDescription => _resolve().debugDescription;

  @override
  @protected
  MouseCursorSession createSession(int device) =>
      _resolve().createSession(device);
}

class _CustomZoomCursor extends MouseCursor {
  const _CustomZoomCursor._(this.name);

  final String name;

  static Future<_CustomZoomCursor> create({
    required String name,
    required IconData icon,
    required int size,
    required int logicalSize,
  }) async {
    final Uint8List rgba = await _paintRgba(icon, size);
    final double hot = size * 0.35;
    if (Platform.isWindows) {
      // Win 引擎未映射 SystemMouseCursors.zoomIn/Out，走官方 createCustomCursor
      await SystemChannels.mouseCursor
          .invokeMethod<String>('createCustomCursor/windows', <String, dynamic>{
            'name': name,
            'buffer': _rgbaToBgra(rgba),
            'width': size,
            'height': size,
            'hotX': hot,
            'hotY': hot,
          });
    } else {
      // macOS / Linux 引擎同样不保证放大镜，经本机通道自绘
      await ZoomCursors._desktop.invokeMethod<void>(
        'cursor.create',
        <String, dynamic>{
          'name': name,
          'buffer': rgba,
          'width': size,
          'height': size,
          'logicalSize': logicalSize,
          'hotX': hot,
          'hotY': hot,
        },
      );
    }
    return _CustomZoomCursor._(name);
  }

  static Future<Uint8List> _paintRgba(IconData icon, int size) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final double s = size.toDouble();
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: s * 0.9,
          color: const Color(0xFF000000),
          shadows: const <Shadow>[
            Shadow(color: Color(0xFFFFFFFF), offset: Offset(1, 0)),
            Shadow(color: Color(0xFFFFFFFF), offset: Offset(-1, 0)),
            Shadow(color: Color(0xFFFFFFFF), offset: Offset(0, 1)),
            Shadow(color: Color(0xFFFFFFFF), offset: Offset(0, -1)),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset((s - painter.width) / 2, (s - painter.height) / 2),
    );
    final ui.Image image = await recorder.endRecording().toImage(size, size);
    final ByteData? raw = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    image.dispose();
    return raw!.buffer.asUint8List();
  }

  static Uint8List _rgbaToBgra(Uint8List rgba) {
    final Uint8List bgra = Uint8List(rgba.length);
    for (int i = 0; i < rgba.length; i += 4) {
      bgra[i] = rgba[i + 2];
      bgra[i + 1] = rgba[i + 1];
      bgra[i + 2] = rgba[i];
      bgra[i + 3] = rgba[i + 3];
    }
    return bgra;
  }

  @override
  String get debugDescription => 'CustomZoomCursor($name)';

  @override
  @protected
  MouseCursorSession createSession(int device) =>
      _CustomZoomCursorSession(this, device);
}

class _CustomZoomCursorSession extends MouseCursorSession {
  _CustomZoomCursorSession(_CustomZoomCursor super.cursor, super.device);

  @override
  Future<void> activate() {
    final String name = (cursor as _CustomZoomCursor).name;
    if (Platform.isWindows) {
      return SystemChannels.mouseCursor.invokeMethod<void>(
        'setCustomCursor/windows',
        <String, dynamic>{'name': name},
      );
    }
    return ZoomCursors._desktop.invokeMethod<void>(
      'cursor.set',
      <String, dynamic>{'name': name},
    );
  }

  @override
  void dispose() {}
}
