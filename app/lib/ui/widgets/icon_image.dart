import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;

import '../../core/app_paths.dart';
import '../../core/logger.dart';
import '../../core/safe_url.dart';

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

  // 一篇富文本里的图片同时开始加载，每张最多 50 MiB 整份进内存，同时下载的数量须封顶
  static const int _maxFetching = 4;
  static int _fetching = 0;
  static final List<Completer<void>> _fetchQueue = <Completer<void>>[];

  static int _generation = 0;
  static bool _clearing = false;
  static final Set<Completer<void>> _downloads = <Completer<void>>{};
  static final Set<Completer<void>> _imageLoads = <Completer<void>>{};

  // 富文本图片每会话合计的下载量，宽松封顶只挡失控的自动加载；用完后新的图片按加载失败显示。
  // 视频由播放器自己拉流，应用数不到这部分流量，只在点击播放时检查预算是否已用完
  static const int _mediaBudget = 200 << 20;
  static int _mediaBytes = 0;

  static bool get mediaBudgetLeft => _mediaBytes < _mediaBudget;

  static bool chargeMedia(int bytes) => (_mediaBytes += bytes) <= _mediaBudget;

  static void resumeSession() => _clearing = false;

  static Future<void> clearSession() async {
    _clearing = true;
    _generation++;
    _mediaBytes = 0;
    for (final Completer<void> abort in _downloads) {
      if (!abort.isCompleted) {
        abort.complete();
      }
    }
    await Future.wait<Object?>(<Future<Object?>>[
      ..._cache.values,
      for (final Completer<void> load in _imageLoads) load.future,
    ]);
    _cache.clear();
  }

  static final Map<String, Future<Uint8List?>> _cache =
      <String, Future<Uint8List?>>{};

  static Future<Uint8List?> _load(String url) {
    if (_clearing) {
      return Future<Uint8List?>.value();
    }
    final int generation = _generation;
    return _cache.putIfAbsent(url, () async {
      final File file = File(
        '${AppPaths.iconCache.path}${Platform.pathSeparator}${_key(url)}',
      );

      try {
        if (file.existsSync()) {
          if (file.lengthSync() > _maxBytes) {
            return null;
          }
          final Uint8List bytes = await file.readAsBytes();
          if (_isImage(bytes)) {
            return generation == _generation ? bytes : null;
          }
        }
        // 地址由面板下发：明文 http 会把用得上哪个策略组暴露在链路上
        final Uri? uri = Uri.tryParse(url);
        if (uri == null || uri.scheme != 'https') {
          Logger.instance.warn('icon', '图标地址不是 https，已忽略：$url');
          return null;
        }

        final Uint8List? bytes = await _fetch(uri);
        if (generation != _generation) {
          return null;
        }
        // 面板地址填错时拿到的多是 HTML 错误页，按魔数挡掉，别把它当图标存下来
        if (bytes == null || !_isImage(bytes)) {
          Logger.instance.warn('icon', '图标取回失败：$url');
          return null;
        }

        await file.writeAsBytes(bytes, flush: true);
        return generation == _generation ? bytes : null;
      } on Object catch (e) {
        if (generation == _generation) {
          Logger.instance.warn('icon', '图标取回失败：$url（$e）');
        }
        return null;
      }
    });
  }

  static Future<Uint8List?> _fetch(
    Uri uri, {
    int maxBytes = _maxBytes,
    Duration timeout = _timeout,
    bool media = false,
    void Function(int received, int? total)? onProgress,
  }) async {
    final Completer<void> abort = Completer<void>();
    _downloads.add(abort);
    if (!await _acquire(abort)) {
      _downloads.remove(abort);
      return null;
    }
    final http.Client client = http.Client();
    final Timer timer = Timer(timeout, () {
      if (!abort.isCompleted) {
        abort.complete();
      }
    });
    try {
      if (abort.isCompleted || (media && !mediaBudgetLeft)) {
        return null;
      }
      final http.StreamedResponse? response = await open(
        client,
        uri,
        abort: abort.future,
        timeout: timeout,
        maxBytes: maxBytes,
      );
      if (response == null) {
        return null;
      }

      final BytesBuilder body = BytesBuilder(copy: false);
      await for (final List<int> chunk in response.stream) {
        if (body.length + chunk.length > maxBytes ||
            (media && !chargeMedia(chunk.length))) {
          return null;
        }
        body.add(chunk);
        onProgress?.call(body.length, response.contentLength);
      }
      return body.takeBytes();
    } finally {
      timer.cancel();
      _downloads.remove(abort);
      client.close();
      _release();
    }
  }

  static Future<bool> _acquire(Completer<void> abort) async {
    if (_fetching < _maxFetching) {
      _fetching++;
      return true;
    }
    final Completer<void> turn = Completer<void>();
    _fetchQueue.add(turn);
    await Future.any(<Future<void>>[turn.future, abort.future]);
    if (turn.isCompleted) {
      return true;
    }
    _fetchQueue.remove(turn);
    return false;
  }

  // 名额直接交给排队中的下一个，不先归还，免得新来的请求插队超出上限
  static void _release() {
    if (_fetchQueue.isEmpty) {
      _fetching--;
    } else {
      _fetchQueue.removeAt(0).complete();
    }
  }

  static Future<http.StreamedResponse?> open(
    http.Client client,
    Uri uri, {
    required Future<void> abort,
    required Duration timeout,
    required int maxBytes,
  }) async {
    if (!SafeUrl.canLoad(uri.toString())) {
      return null;
    }
    http.StreamedResponse response;
    final bool requireHttps = uri.scheme == 'https';
    int redirects = 0;
    while (true) {
      response = await client
          .send(
            http.AbortableRequest('GET', uri, abortTrigger: abort)
              ..followRedirects = false,
          )
          .timeout(timeout);
      if (!response.isRedirect) {
        break;
      }
      await response.stream.listen(null).cancel();
      final String? location = response.headers['location'];
      if (location == null || redirects++ >= 5) {
        return null;
      }
      final Uri? redirect = Uri.tryParse(location);
      if (redirect == null) {
        return null;
      }
      uri = uri.resolveUri(redirect);
      if (!SafeUrl.canLoad(uri.toString()) ||
          (requireHttps && uri.scheme != 'https')) {
        return null;
      }
    }
    if (response.statusCode != 200 ||
        (response.contentLength ?? 0) > maxBytes) {
      return null;
    }
    return response;
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

  static String _key(String url) => sha256.convert(utf8.encode(url)).toString();

  @override
  Widget build(BuildContext context) => _IconBytes(
    bytes: _load(url),
    width: width,
    height: height,
    fit: fit,
    fallback: fallback,
  );
}

class RemoteImage extends ImageProvider<RemoteImage> {
  RemoteImage(this.url) : _generation = RemoteIcon._generation;

  final String url;
  final int _generation;

  @override
  Future<RemoteImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<RemoteImage>(this);

  @override
  ImageStreamCompleter loadImage(RemoteImage key, ImageDecoderCallback decode) {
    final StreamController<ImageChunkEvent> chunks =
        StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: key._load(decode, chunks),
      scale: 1,
      chunkEvents: chunks.stream,
    );
  }

  bool get _current =>
      !RemoteIcon._clearing && _generation == RemoteIcon._generation;

  Future<ui.Codec> _load(
    ImageDecoderCallback decode,
    StreamController<ImageChunkEvent> chunks,
  ) async {
    final Completer<void> done = Completer<void>();
    RemoteIcon._imageLoads.add(done);
    try {
      if (!_current || !SafeUrl.canLoad(url)) {
        throw StateError('图片会话已结束或地址无效');
      }
      final Uint8List? bytes = await RemoteIcon._fetch(
        Uri.parse(url.trim()),
        maxBytes: 50 << 20,
        timeout: const Duration(seconds: 30),
        media: true,
        onProgress: (int received, int? total) => chunks.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: received,
            expectedTotalBytes: total,
          ),
        ),
      );
      if (!_current || bytes == null || bytes.isEmpty) {
        throw StateError('图片加载已取消或内容无效');
      }
      final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
        bytes,
      );
      if (!_current) {
        buffer.dispose();
        throw StateError('图片会话已结束');
      }
      final ui.Codec codec = await decode(buffer);
      if (!_current) {
        codec.dispose();
        throw StateError('图片会话已结束');
      }
      return codec;
    } catch (_) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      rethrow;
    } finally {
      unawaited(chunks.close());
      RemoteIcon._imageLoads.remove(done);
      done.complete();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteImage &&
      other.url == url &&
      other._generation == _generation;

  @override
  int get hashCode => Object.hash(url, _generation);
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
        // 魔数对得上但解不开的文件（下载截断、面板给了坏图）退回内置图形
        return data.first == 0x3C
            ? SvgPicture.memory(
                data,
                fit: fit,
                errorBuilder: (BuildContext _, Object _, StackTrace _) =>
                    fallback,
              )
            : Image.memory(
                data,
                fit: fit,
                gaplessPlayback: true,
                errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                    fallback,
              );
      },
    ),
  );
}
