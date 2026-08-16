import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';

import '../../core/safe_url.dart';
import '../app_scope.dart';
import '../shell_navigator.dart';
import '../../l10n/l10n.dart';
import 'image_viewer.dart';
import 'zoom_cursors.dart';

/// 从若干段 HTML 中按出现顺序收集去重后的 img src（与网站 collectImageList 同口径）。
List<String> collectHtmlImageSrcs(Iterable<String> htmlFragments) {
  final RegExp re = RegExp(
    r'''<img\b[^>]*?\bsrc\s*=\s*(["'])(.*?)\1''',
    caseSensitive: false,
  );
  final List<String> out = <String>[];
  for (final String html in htmlFragments) {
    for (final RegExpMatch match in re.allMatches(html)) {
      final String src = _decodeHtmlSrc(match.group(2) ?? '').trim();
      if (src.isNotEmpty && !out.contains(src)) {
        out.add(src);
      }
    }
  }
  return out;
}

String _decodeHtmlSrc(String value) {
  return value
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");
}

/// 渲染面板下发的安全 HTML（文字格式 / 图片 / 视频链接）。
class RichHtmlView extends StatelessWidget {
  const RichHtmlView(this.html, {super.key, this.imageAlbum});

  final String html;

  /// 非空时放大浏览使用该相册（如工单整单会话）；空则仅本段 HTML 内的图。
  final List<String>? imageAlbum;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String source = html.trim();
    if (source.isEmpty) {
      return const SizedBox.shrink();
    }

    // 必须带上主题字族：flutter_html 的 TextStyle 不走 DefaultTextStyle 合并，
    // 面板富文本还常写 font-family；自定义样式在 inline 之后合并，用 * 盖住。
    final TextStyle body = theme.textTheme.bodyMedium!;
    final Style uiFont = Style(
      fontFamily: body.fontFamily,
      fontFamilyFallback: body.fontFamilyFallback,
    );

    final String base = AppScope.of(context).auth.siteOrigin;

    return Html(
      data: source,
      doNotRenderTheseTags: _blockedTags,
      style: <String, Style>{
        ...Style.fromThemeData(theme),
        'body': Style.fromTextStyle(body).copyWith(
          margin: Margins.zero,
          padding: HtmlPaddings.zero,
          lineHeight: const LineHeight(1.45),
          color: theme.colorScheme.onSurface,
        ),
        'p': Style(margin: Margins.only(bottom: 6)),
        'hr': Style(
          margin: Margins.symmetric(vertical: 10),
          height: Height(1),
          border: Border(
            top: BorderSide(color: theme.dividerColor, width: 1),
          ),
          backgroundColor: theme.dividerColor,
        ),
        'a': Style(
          color: theme.colorScheme.primary,
          textDecoration: TextDecoration.underline,
        ),
        '*': uiFont,
        'code': Style(fontFamily: 'monospace'),
        'pre': Style(fontFamily: 'monospace'),
        'kbd': Style(fontFamily: 'monospace'),
        'samp': Style(fontFamily: 'monospace'),
      },
      extensions: <HtmlExtension>[
        TagExtension.inline(
          tagsToExtend: <String>{'a'},
          builder: (ExtensionContext ctx) {
            final String? href = ctx.attributes['href'];
            final bool canTap = href != null && _canTapLink(href, base);
            final TextStyle? linkStyle = ctx.style?.generateTextStyle();
            final Widget label = Text.rich(
              TextSpan(
                children: ctx.inlineSpanChildren,
                style: linkStyle,
              ),
            );
            final Widget link = MouseRegion(
              cursor: canTap
                  ? SystemMouseCursors.click
                  : MouseCursor.defer,
              child: GestureDetector(
                onTap: canTap
                    ? () => ctx.parser.internalOnAnchorTap?.call(
                          href,
                          ctx.attributes,
                          ctx.element,
                        )
                    : null,
                child: label,
              ),
            );
            return WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: canTap ? Tooltip(message: href, child: link) : link,
            );
          },
        ),
        TagExtension(
          tagsToExtend: <String>{'img'},
          builder: (ExtensionContext ctx) {
            final String? src = _httpUrl(ctx.attributes['src'] ?? '', base);
            if (src == null) {
              return const SizedBox.shrink();
            }
            return _TicketImage(
              src,
              alt: ctx.attributes['alt'] ?? '',
              // 与网站 collectImageList 同一口径：有外部相册用外部，否则本段富文本内切换
              album: () {
                final Iterable<String> raw = imageAlbum ??
                    ctx.parser.htmlData
                        .querySelectorAll('img')
                        .map((e) => e.attributes['src'] ?? '')
                        .where((String url) => url.isNotEmpty);
                final List<String> out = <String>[];
                for (final String url in raw) {
                  final String? ok = _httpUrl(url, base);
                  if (ok != null && !out.contains(ok)) {
                    out.add(ok);
                  }
                }
                return out;
              },
            );
          },
        ),
        TagExtension(
          tagsToExtend: <String>{'video'},
          builder: (ExtensionContext ctx) {
            final String? src = _httpUrl(ctx.attributes['src'] ?? '', base);
            if (src == null) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: OutlinedButton.icon(
                onPressed: () =>
                    AppScope.of(context).platform.openUrl(src),
                icon: const Icon(Icons.play_circle_outline, size: 18),
                label: Text(L10n.t('播放视频')),
              ),
            );
          },
        ),
      ],
      onLinkTap: (String? url, Map<String, String> attributes, _) {
        if (url == null || url.isEmpty) {
          return;
        }
        if (_isUserTicketLink(url) && ShellNavigator.openTickets(context)) {
          return;
        }
        final String? abs = _openableLink(url, base);
        if (abs == null) {
          return;
        }
        AppScope.of(context).platform.openUrl(abs);
      },
    );
  }

  static const Set<String> _blockedTags = <String>{
    'script',
    'iframe',
    'object',
    'embed',
    'form',
    'input',
    'button',
    'select',
    'textarea',
    'style',
    'link',
    'meta',
    'base',
    'svg',
    'math',
    'applet',
    'frame',
    'frameset',
  };

  static String _absolute(String url, String base) => url.startsWith('/')
      ? '${base.replaceAll(RegExp(r'/+$'), '')}$url'
      : url;

  static String? _httpUrl(String url, String base) {
    if (url.isEmpty) {
      return null;
    }
    final String abs = _absolute(url, base);
    return SafeUrl.canLoad(abs) ? abs : null;
  }

  static String? _openableLink(String url, String base) {
    if (url.isEmpty) {
      return null;
    }
    final String abs = _absolute(url, base);
    return SafeUrl.canOpenLink(abs) ? abs : null;
  }

  static bool _canTapLink(String href, String base) =>
      _isUserTicketLink(href) || _openableLink(href, base) != null;

  static bool _isUserTicketLink(String url) {
    final String path = url.startsWith('/')
        ? url.split('?').first
        : (Uri.tryParse(url)?.path ?? '');
    return path == '/user/ticket' || path.startsWith('/user/ticket/');
  }
}

/// 失败 URL 全局记住，避免 ListView / Html 重建时 Image.network 反复重试导致高度闪烁。
class _TicketImage extends StatefulWidget {
  const _TicketImage(this.src, {required this.alt, required this.album});

  final String src;
  final String alt;
  final List<String> Function() album;

  static final Set<String> _failed = <String>{};

  @override
  State<_TicketImage> createState() => _TicketImageState();
}

class _TicketImageState extends State<_TicketImage> {
  static const double _maxWidth = 360;
  static const double _maxHeight = 240;
  static const double _placeholderHeight = 48;

  late bool _failed;

  @override
  void initState() {
    super.initState();
    _failed = _TicketImage._failed.contains(widget.src);
  }

  @override
  void didUpdateWidget(covariant _TicketImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.src != widget.src) {
      _failed = _TicketImage._failed.contains(widget.src);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: _maxWidth,
            maxHeight: _maxHeight,
          ),
          child: _failed
              ? _placeholder(theme)
              : MouseRegion(
                  cursor: ZoomCursors.zoomIn,
                  child: GestureDetector(
                    onTap: () {
                      final List<String> album = widget.album();
                      if (album.isEmpty) {
                        return;
                      }
                      int index = album.indexOf(widget.src);
                      if (index < 0) {
                        index = 0;
                      }
                      showImageViewer(context, images: album, index: index);
                    },
                    child: Image.network(
                      widget.src,
                      key: ValueKey<String>('ticket-img-${widget.src}'),
                      fit: BoxFit.contain,
                      alignment: Alignment.centerLeft,
                      gaplessPlayback: true,
                      errorBuilder:
                          (
                            BuildContext context,
                            Object error,
                            StackTrace? stack,
                          ) {
                            _TicketImage._failed.add(widget.src);
                            // errorBuilder 内同步标失败即可；勿再 setState 触发二次布局抖动
                            _failed = true;
                            return _placeholder(theme);
                          },
                      loadingBuilder:
                          (
                            BuildContext context,
                            Widget child,
                            ImageChunkEvent? progress,
                          ) {
                            if (progress == null) {
                              return child;
                            }
                            // 与失败占位同高，避免 loading ↔ error 切换时列表上下跳
                            return const SizedBox(
                              width: _maxWidth,
                              height: _placeholderHeight,
                              child: Center(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            );
                          },
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _placeholder(ThemeData theme) {
    return Container(
      width: _maxWidth,
      height: _placeholderHeight,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.broken_image_outlined,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.alt.isEmpty
                  ? L10n.t('附件已删除或无法加载')
                  : L10n.t('无法加载：{0}', <Object>[widget.alt]),
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
