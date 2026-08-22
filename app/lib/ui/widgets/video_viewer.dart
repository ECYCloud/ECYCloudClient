import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/app_paths.dart';
import '../../core/logger.dart';
import '../../l10n/l10n.dart';

class HtmlVideoView extends StatefulWidget {
  const HtmlVideoView(this.src, {super.key, this.onRemove});

  final String src;
  final VoidCallback? onRemove;

  @override
  State<HtmlVideoView> createState() => _HtmlVideoViewState();
}

class _HtmlVideoViewState extends State<HtmlVideoView> {
  static const double _maxWidth = 360;
  static const double _maxHeight = 240;

  Player? _player;
  VideoController? _controller;
  StreamSubscription<int?>? _sizeSub;
  File? _poster;
  bool _ready = false;
  bool _failed = false;
  bool _posterSaved = false;

  @override
  void initState() {
    super.initState();
    _poster = _HtmlVideoCache.posterOf(widget.src);
    _attach(widget.src);
  }

  @override
  void didUpdateWidget(covariant HtmlVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.src != widget.src) {
      _detach();
      _ready = false;
      _failed = false;
      _posterSaved = false;
      _poster = _HtmlVideoCache.posterOf(widget.src);
      _attach(widget.src);
    }
  }

  void _attach(String src) {
    try {
      MediaKit.ensureInitialized();
      final Player player = Player();
      _player = player;
      _controller = VideoController(player);
      _sizeSub = player.stream.width.listen((int? width) {
        if (!mounted || width == null || width <= 0) {
          return;
        }
        if (!_ready) {
          setState(() => _ready = true);
        }
        if (!_posterSaved) {
          _posterSaved = true;
          unawaited(_capturePoster(player, src));
        }
      });
      unawaited(_open(player, src));
    } catch (_) {
      _failed = true;
    }
  }

  Future<void> _open(Player player, String src) async {
    try {
      final File? cached = _HtmlVideoCache.videoOf(src);
      try {
        // 网站 <video preload="metadata">：停在首帧当封面，禁止自动播放
        await player.open(Media(cached?.uri.toString() ?? src), play: false);
      } catch (_) {
        if (cached == null) {
          rethrow;
        }
        cached.deleteSync();
        await player.open(Media(src), play: false);
      }
      if (cached == null) {
        unawaited(_HtmlVideoCache.prefetch(src));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _failed = true);
      }
    }
  }

  Future<void> _capturePoster(Player player, String src) async {
    if (_HtmlVideoCache.posterOf(src) != null) {
      return;
    }
    try {
      final Uint8List? bytes = await player.screenshot();
      if (bytes == null || bytes.isEmpty) {
        return;
      }
      await _HtmlVideoCache.savePoster(src, bytes);
    } catch (_) {}
  }

  void _detach() {
    unawaited(_sizeSub?.cancel());
    _sizeSub = null;
    unawaited(_player?.dispose());
    _player = null;
    _controller = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final VideoController? controller = _controller;
    final File? poster = _poster;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: _maxWidth,
            height: _maxHeight,
            child: Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.hardEdge,
              children: <Widget>[
                if (_failed || controller == null)
                  _placeholder(theme)
                else ...<Widget>[
                  Video(controller: controller, fit: BoxFit.contain),
                  if (!_ready && poster != null)
                    ColoredBox(
                      color: Colors.black,
                      child: Image.file(
                        poster,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    )
                  else if (!_ready)
                    const ColoredBox(
                      color: Colors.black,
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                ],
                if (widget.onRemove != null)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Material(
                      type: MaterialType.transparency,
                      child: IconButton(
                        tooltip: L10n.t('删除'),
                        icon: const Icon(Icons.close),
                        onPressed: widget.onRemove,
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black54,
                          foregroundColor: Colors.white,
                          iconSize: 18,
                          fixedSize: const Size.square(32),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholder(ThemeData theme) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Center(
        child: Text(L10n.t('无法播放视频'), style: theme.textTheme.bodySmall),
      ),
    );
  }
}

class _HtmlVideoCache {
  _HtmlVideoCache._();

  // 单文件与面板工单上传上限同值；整目录再封顶，避免把用户目录写满
  static const int _maxFile = 50 << 20;
  static const int _maxTotal = 200 << 20;

  static final Map<String, Future<void>> _jobs = <String, Future<void>>{};

  static File? videoOf(String url) => _existing(_videoFile(url));

  static File? posterOf(String url) => _existing(_posterFile(url));

  static Future<void> savePoster(String url, Uint8List bytes) async {
    final File file = _posterFile(url);
    await file.writeAsBytes(bytes, flush: true);
    _evict(keep: file);
  }

  static Future<void> prefetch(String url) => _jobs.putIfAbsent(url, () async {
    try {
      await _download(url);
    } finally {
      _jobs.remove(url);
    }
  });

  static Future<void> _download(String url) async {
    final File dest = _videoFile(url);
    if (_existing(dest) != null) {
      return;
    }
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return;
    }
    final File part = File('${dest.path}.part');
    final http.Client client = http.Client();
    try {
      final http.StreamedResponse response = await client
          .send(http.Request('GET', uri))
          .timeout(const Duration(seconds: 120));
      if (response.statusCode != 200) {
        return;
      }
      final int? length = response.contentLength;
      if (length != null && length > _maxFile) {
        return;
      }
      final IOSink sink = part.openWrite();
      int written = 0;
      try {
        await for (final List<int> chunk in response.stream) {
          written += chunk.length;
          if (written > _maxFile) {
            await sink.close();
            _delete(part);
            return;
          }
          sink.add(chunk);
        }
        await sink.flush();
        await sink.close();
      } catch (_) {
        await sink.close();
        _delete(part);
        rethrow;
      }
      if (written == 0) {
        _delete(part);
        return;
      }
      if (dest.existsSync()) {
        dest.deleteSync();
      }
      part.renameSync(dest.path);
      _evict(keep: dest);
    } on Object catch (e) {
      _delete(part);
      Logger.instance.warn('video', '视频缓存失败：$url（$e）');
    } finally {
      client.close();
    }
  }

  static File? _existing(File file) =>
      file.existsSync() && file.lengthSync() > 0 ? file : null;

  static void _delete(File file) {
    if (file.existsSync()) {
      file.deleteSync();
    }
  }

  static void _evict({File? keep}) {
    final List<File> files = AppPaths.videoCache
        .listSync()
        .whereType<File>()
        .where((File file) => !file.path.endsWith('.part'))
        .toList();
    files.sort(
      (File a, File b) =>
          a.statSync().modified.compareTo(b.statSync().modified),
    );
    int total = 0;
    for (final File file in files) {
      total += file.lengthSync();
    }
    for (final File file in files) {
      if (total <= _maxTotal) {
        return;
      }
      if (keep != null && file.path == keep.path) {
        continue;
      }
      total -= file.lengthSync();
      _delete(file);
    }
  }

  static File _videoFile(String url) =>
      File('${AppPaths.videoCache.path}${Platform.pathSeparator}${_key(url)}');

  static File _posterFile(String url) => File(
    '${AppPaths.videoCache.path}${Platform.pathSeparator}${_key(url)}.jpg',
  );

  static String _key(String url) {
    int hash = 0x811C9DC5;
    for (final int unit in url.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
