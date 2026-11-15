import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/app_paths.dart';
import '../../l10n/l10n.dart';
import 'icon_image.dart';

class HtmlVideoView extends StatefulWidget {
  const HtmlVideoView(this.src, {super.key, this.onRemove});

  final String src;
  final VoidCallback? onRemove;

  static final Map<Player, Future<void>?> _players = <Player, Future<void>?>{};

  static void resumeSession() => _HtmlVideoCache._clearing = false;

  static Future<void> clearSession() async {
    // 先停掉新的封面读写与播放，再释放播放器、删缓存目录
    _HtmlVideoCache._clearing = true;
    _HtmlVideoCache._generation++;
    await Future.wait(<Future<void>>[
      for (final Player player in _players.keys.toList())
        _disposePlayer(player),
    ]);
    await _HtmlVideoCache.clearSession();
  }

  static Future<void> _disposePlayer(Player player) {
    if (!_players.containsKey(player)) {
      return Future<void>.value();
    }
    return _players[player] ??= player.dispose().then((_) {
      _players.remove(player);
    });
  }

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

  // 点击前不建播放器也不预取，正文里的视频不会自己消耗流量
  @override
  void initState() {
    super.initState();
    _poster = _HtmlVideoCache.posterOf(widget.src);
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
    }
  }

  void _attach(String src) {
    if (_HtmlVideoCache._clearing || !RemoteIcon.mediaBudgetLeft) {
      _failed = true;
      return;
    }
    final int generation = _HtmlVideoCache._generation;
    try {
      MediaKit.ensureInitialized();
      final Player player = Player(
        configuration: const PlayerConfiguration(
          protocolWhitelist: <String>['http', 'https', 'tcp', 'tls', 'crypto'],
        ),
      );
      HtmlVideoView._players[player] = null;
      final PlatformPlayer? backend = player.platform;
      if (backend is NativePlayer) {
        // media_kit 自己用 loadlist；仅限制实际媒体，防止缓存播放列表读取本地文件。
        backend.onLoadHooks.add(
          () =>
              backend.setProperty('file-local-options/access-references', 'no'),
        );
      }
      _player = player;
      _controller = VideoController(player);
      _sizeSub = player.stream.width.listen((int? width) {
        if (!mounted ||
            !identical(player, _player) ||
            generation != _HtmlVideoCache._generation ||
            width == null ||
            width <= 0) {
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
    final int generation = _HtmlVideoCache._generation;
    bool isCurrent() =>
        mounted &&
        identical(player, _player) &&
        generation == _HtmlVideoCache._generation;
    try {
      final File? cached = _HtmlVideoCache.videoOf(src);
      try {
        // 用户点了封面上的播放才走到这里，打开即播放
        await player.open(Media(cached?.uri.toString() ?? src));
      } catch (_) {
        if (!isCurrent()) {
          return;
        }
        if (cached == null) {
          rethrow;
        }
        cached.deleteSync();
        await player.open(Media(src));
      }
    } catch (_) {
      if (isCurrent()) {
        setState(() => _failed = true);
      }
    }
  }

  Future<void> _capturePoster(Player player, String src) async {
    final int generation = _HtmlVideoCache._generation;
    if (_HtmlVideoCache.posterOf(src) != null) {
      return;
    }
    try {
      final Uint8List? bytes = await player.screenshot();
      if (!mounted ||
          !identical(player, _player) ||
          generation != _HtmlVideoCache._generation ||
          bytes == null ||
          bytes.isEmpty) {
        return;
      }
      await _HtmlVideoCache.savePoster(src, bytes);
    } catch (_) {}
  }

  void _detach() {
    unawaited(_sizeSub?.cancel());
    _sizeSub = null;
    final Player? player = _player;
    if (player != null) {
      unawaited(HtmlVideoView._disposePlayer(player).catchError((Object _) {}));
    }
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
                if (_failed)
                  _placeholder(theme)
                else if (controller == null)
                  _cover(poster)
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

  // 遥控器要能选中它，点击控件必须是可聚焦的 Material 组件
  Widget _cover(File? poster) => Material(
    color: Colors.black,
    child: InkWell(
      onTap: () => setState(() => _attach(widget.src)),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (poster != null)
            Image.file(poster, fit: BoxFit.contain, gaplessPlayback: true),
          Center(
            child: Icon(
              Icons.play_circle_outline,
              size: 48,
              color: Colors.white,
              semanticLabel: L10n.t('播放视频'),
            ),
          ),
        ],
      ),
    ),
  );

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

  // 播放器自己拉流，不再另行预取整份视频（否则首次播放下两遍）；目录里只剩封面与旧版本留下的缓存，整体封顶
  static const int _maxTotal = 200 << 20;

  static final Set<Future<void>> _posters = <Future<void>>{};
  static int _generation = 0;
  static bool _clearing = false;

  static Future<void> clearSession() async {
    await Future.wait(<Future<void>>[..._posters]);
  }

  static File? videoOf(String url) =>
      _clearing ? null : _existing(_videoFile(url));

  static File? posterOf(String url) =>
      _clearing ? null : _existing(_posterFile(url));

  static Future<void> savePoster(String url, Uint8List bytes) async {
    if (_clearing) {
      return;
    }
    final int generation = _generation;
    final File file = _posterFile(url);
    final Future<void> pending = file.writeAsBytes(bytes, flush: true).then((
      _,
    ) {
      if (generation == _generation) {
        _evict(keep: file);
      }
    });
    _posters.add(pending);
    try {
      await pending;
    } finally {
      _posters.remove(pending);
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
    final List<File> all = AppPaths.videoCache
        .listSync()
        .whereType<File>()
        .toList();
    int total = 0;
    for (final File file in all) {
      total += file.lengthSync();
    }
    final List<File> files = all
        .where((File file) => !file.path.endsWith('.part'))
        .toList();
    files.sort(
      (File a, File b) =>
          a.statSync().modified.compareTo(b.statSync().modified),
    );
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

  static String _key(String url) => sha256.convert(utf8.encode(url)).toString();
}
