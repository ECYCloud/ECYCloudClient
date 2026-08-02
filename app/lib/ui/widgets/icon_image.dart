import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;

import '../../core/app_paths.dart';
import '../../core/logger.dart';

/// 随包资源里的图标，取 [assets] 里第一个存在的；都不存在时用 [fallback]。
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

/// 面板下发地址的图标（策略组图标）。首次显示时下载并落盘到用户数据目录，
/// 之后一律读本地文件；地址变了缓存名也变，面板换图标自动生效。取不到就用 [fallback]。
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

          final http.Response response = await http
              .get(Uri.parse(url))
              .timeout(_timeout);
          final Uint8List bytes = response.bodyBytes;

          // 面板地址填错时拿到的多是 HTML 错误页，按首字节挡掉，别把它当图标存下来
          if (response.statusCode != 200 || !_isImage(bytes)) {
            Logger.instance.warn(
              'icon',
              '图标取回失败（HTTP ${response.statusCode}）：$url',
            );
            return null;
          }

          await file.writeAsBytes(bytes, flush: true);
          return bytes;
        } on Object catch (e) {
          Logger.instance.warn('icon', '图标取回失败：$url（$e）');
          return null;
        }
      });

  // PNG / JPEG / GIF / WebP(RIFF) 按魔数认，SVG 认起始的 '<'
  static bool _isImage(Uint8List bytes) =>
      bytes.length > 8 &&
      (bytes[0] == 0x89 ||
          bytes[0] == 0xFF ||
          bytes[0] == 0x47 ||
          bytes[0] == 0x52 ||
          bytes[0] == 0x3C);

  // 缓存文件名只需稳定且随地址变化，用 FNV-1a
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
        // PNG 与 SVG 都可能，按首字节区分
        return data.first == 0x3C
            ? SvgPicture.memory(data, fit: fit)
            : Image.memory(data, fit: fit, gaplessPlayback: true);
      },
    ),
  );
}
