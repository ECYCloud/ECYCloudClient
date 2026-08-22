import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract final class ZoomCursors {
  static MouseCursor _zoomIn = SystemMouseCursors.zoomIn;
  static MouseCursor _zoomOut = SystemMouseCursors.zoomOut;

  static MouseCursor get zoomIn => _zoomIn;
  static MouseCursor get zoomOut => _zoomOut;

  static Future<void> ensureReady() async {
    // Win 引擎未映射 SystemMouseCursors.zoomIn/Out（回退成箭头），须 createCustomCursor
    if (kIsWeb || !Platform.isWindows) {
      return;
    }
    final double dpr = ui.PlatformDispatcher.instance.views.isEmpty
        ? 1.0
        : ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
    final int size = (32 * dpr).round().clamp(32, 128);
    try {
      _zoomIn = await _WindowsZoomCursor.create(
        name: 'ecycloud_zoom_in',
        icon: Icons.zoom_in,
        size: size,
      );
      _zoomOut = await _WindowsZoomCursor.create(
        name: 'ecycloud_zoom_out',
        icon: Icons.zoom_out,
        size: size,
      );
    } on Object {
      _zoomIn = SystemMouseCursors.zoomIn;
      _zoomOut = SystemMouseCursors.zoomOut;
    }
  }
}

class _WindowsZoomCursor extends MouseCursor {
  const _WindowsZoomCursor._(this.name);

  final String name;

  static Future<_WindowsZoomCursor> create({
    required String name,
    required IconData icon,
    required int size,
  }) async {
    final Uint8List buffer = await _paintBgra(icon, size);
    await SystemChannels.mouseCursor
        .invokeMethod<String>('createCustomCursor/windows', <String, dynamic>{
          'name': name,
          'buffer': buffer,
          'width': size,
          'height': size,
          'hotX': size * 0.35,
          'hotY': size * 0.35,
        });
    return _WindowsZoomCursor._(name);
  }

  static Future<Uint8List> _paintBgra(IconData icon, int size) async {
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
    final Uint8List rgba = raw!.buffer.asUint8List();
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
  String get debugDescription => 'WindowsZoomCursor($name)';

  @override
  @protected
  MouseCursorSession createSession(int device) =>
      _WindowsZoomCursorSession(this, device);
}

class _WindowsZoomCursorSession extends MouseCursorSession {
  _WindowsZoomCursorSession(_WindowsZoomCursor super.cursor, super.device);

  @override
  Future<void> activate() {
    return SystemChannels.mouseCursor.invokeMethod<void>(
      'setCustomCursor/windows',
      <String, dynamic>{'name': (cursor as _WindowsZoomCursor).name},
    );
  }

  @override
  void dispose() {}
}
