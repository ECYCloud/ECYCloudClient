import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;

import '../../core/app_paths.dart';
import '../../core/logger.dart';

class LocalIcon extends StatelessWidget {
  const LocalIcon({
    super.key,
    required this.assets,
    required this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.fallback = const SizedBox.shrink(),
  });

  final List<String> assets;
  final double width;
  final double? height;
  final BoxFit fit;
  final Widget fallback;

  // 同一张图在列表里出现几十次，字节缓存下来才能命中 flutter_svg / Image 的图片缓存
  static final Map<String, Future<Uint8List?>> _cache =
      <String, Future<Uint8List?>>{};

  static Future<Uint8List?> _load(List<String> assets) =>
      _cache.putIfAbsent(assets.join('|'), () async {
        for (final String asset in assets) {
          try {
            final ByteData data = await rootBundle.load(asset);
            return data.buffer.asUint8List();
          } on Object {
            continue;
          }
        }
        return null;
      });

  @override
  Widget build(BuildContext context) => _IconBytes(
    bytes: _load(assets),
    width: width,
    height: height,
    fit: fit,
    fallback: fallback,
  );
}

class RemoteIcon extends StatelessWidget {
  const RemoteIcon({
    super.key,
    required this.url,
    required this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.fallback = const SizedBox.shrink(),
  });

  final String url;
  final double width;
  final double? height;
  final BoxFit fit;
  final Widget fallback;

  static const Duration _timeout = Duration(seconds: 10);

  // 图标是几 KB 的量级，给到 1 MiB 已经宽松；没有上限的话，地址指到大文件上
  // 就会把整份响应读进内存
  static const int _maxBytes = 1 << 20;

  static final Map<String, Future<Uint8List?>> _cache =
      <String, Future<Uint8List?>>{};

  static Future<Uint8List?> _load(String url) =>
      _cache.putIfAbsent(url, () async {
        final File file = File(
          '${AppPaths.iconCache.path}${Platform.pathSeparator}${_key(url)}',
        );

        try {
          if (file.existsSync()) {
            return await file.readAsBytes();
          }
          // 地址由面板下发：明文 http 会把用得上哪个策略组暴露在链路上
          final Uri? uri = Uri.tryParse(url);
          if (uri == null || uri.scheme != 'https') {
            Logger.instance.warn('icon', '图标地址不是 https，已忽略：$url');
            return null;
          }

          final Uint8List? bytes = await _fetch(uri);
          // 面板地址填错时拿到的多是 HTML 错误页，按魔数挡掉，别把它当图标存下来
          if (bytes == null || !_isImage(bytes)) {
            Logger.instance.warn('icon', '图标取回失败：$url');
            return null;
          }

          await file.writeAsBytes(bytes, flush: true);
          return bytes;
        } on Object catch (e) {
          Logger.instance.warn('icon', '图标取回失败：$url（$e）');
          return null;
        }
      });

  static Future<Uint8List?> _fetch(Uri uri) async {
    final http.Client client = http.Client();
    try {
      final http.StreamedResponse response = await client
          .send(http.Request('GET', uri))
          .timeout(_timeout);
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > _maxBytes) {
        return null;
      }

      final List<int> body = <int>[];
      await for (final List<int> chunk in response.stream) {
        body.addAll(chunk);
        if (body.length > _maxBytes) {
          return null;
        }
      }
      return Uint8List.fromList(body);
    } finally {
      client.close();
    }
  }

  // PNG / JPEG / GIF / WebP 按各自魔数认；SVG 必须以 <svg 或 <?xml 起头，
  // 只认 '<' 会把 HTML 错误页也当成图标缓存下来
  static bool _isImage(Uint8List bytes) {
    if (bytes.length < 12) {
      return false;
    }
    if (_startsWith(bytes, <int>[0x89, 0x50, 0x4E, 0x47]) ||
        _startsWith(bytes, <int>[0xFF, 0xD8, 0xFF]) ||
        _startsWith(bytes, <int>[0x47, 0x49, 0x46, 0x38])) {
      return true;
    }
    if (_startsWith(bytes, <int>[0x52, 0x49, 0x46, 0x46]) &&
        _startsWith(bytes.sublist(8), <int>[0x57, 0x45, 0x42, 0x50])) {
      return true;
    }
    final String head = String.fromCharCodes(
      bytes.sublist(0, bytes.length < 64 ? bytes.length : 64),
    ).toLowerCase();
    return head.startsWith('<svg') || head.startsWith('<?xml');
  }

  static bool _startsWith(Uint8List bytes, List<int> magic) {
    for (int i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        return false;
      }
    }
    return true;
  }

  static String _key(String url) {
    int hash = 0x811C9DC5;
    for (final int unit in url.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  @override
  Widget build(BuildContext context) => _IconBytes(
    bytes: _load(url),
    width: width,
    height: height,
    fit: fit,
    fallback: fallback,
  );
}

class _IconBytes extends StatelessWidget {
  const _IconBytes({
    required this.bytes,
    required this.width,
    required this.height,
    required this.fit,
    required this.fallback,
  });

  final Future<Uint8List?> bytes;
  final double width;
  final double? height;
  final BoxFit fit;
  final Widget fallback;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height ?? width,
    child: FutureBuilder<Uint8List?>(
      future: bytes,
      builder: (BuildContext context, AsyncSnapshot<Uint8List?> snapshot) {
        final Uint8List? data = snapshot.data;
        if (data == null) {
          return snapshot.connectionState == ConnectionState.done
              ? fallback
              : const SizedBox.shrink();
        }
        return data.first == 0x3C
            ? SvgPicture.memory(data, fit: fit)
            : Image.memory(data, fit: fit, gaplessPlayback: true);
      },
    ),
  );
}
