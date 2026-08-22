import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';

import '../../core/safe_url.dart';
import '../app_scope.dart';
import '../shell_navigator.dart';
import '../../l10n/l10n.dart';
import '../pages/account_page.dart';
import '../pages/balance_records_page.dart';
import '../pages/delete_account_page.dart';
import '../pages/edit_account_page.dart';
import '../pages/invite_page.dart';
import '../pages/operation_logs_page.dart';
import '../pages/purchases_page.dart';
import '../pages/recharge_page.dart';
import '../pages/traffic_log_page.dart';
import 'image_viewer.dart';
import 'video_viewer.dart';
import 'zoom_cursors.dart';

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

class RichHtmlView extends StatelessWidget {
  const RichHtmlView(this.html, {super.key, this.imageAlbum});

  final String html;
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
          border: Border(top: BorderSide(color: theme.dividerColor, width: 1)),
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
              TextSpan(children: ctx.inlineSpanChildren, style: linkStyle),
            );
            final Widget link = MouseRegion(
              cursor: canTap ? SystemMouseCursors.click : MouseCursor.defer,
              child: InkWell(
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
              album: () {
                final Iterable<String> raw =
                    imageAlbum ??
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
            final String? src = _videoUrl(ctx, base);
            if (src == null) {
              return const SizedBox.shrink();
            }
            return HtmlVideoView(src, key: ValueKey<String>(src));
          },
        ),
      ],
      onLinkTap: (String? url, Map<String, String> attributes, _) {
        if (url == null || url.isEmpty) {
          return;
        }
        if (_openInApp(context, _appRoute(url, base))) {
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

  static String _absolute(String url, String base) =>
      url.startsWith('/') ? '${base.replaceAll(RegExp(r'/+$'), '')}$url' : url;

  static String? _videoUrl(ExtensionContext ctx, String base) {
    final List<String> candidates = <String>[ctx.attributes['src'] ?? ''];
    for (final child in ctx.elementChildren) {
      if (child.localName == 'source') {
        candidates.add(child.attributes['src'] ?? '');
      }
    }
    for (final String url in candidates) {
      final String? ok = _httpUrl(url, base);
      if (ok != null) {
        return ok;
      }
    }
    return null;
  }

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
      _appRoute(href, base).isNotEmpty || _openableLink(href, base) != null;

  static int? _tabOf(String route) => switch (route) {
    '/user' => ShellNavigator.homeTab,
    '/user/node' => ShellNavigator.nodesTab,
    '/user/shop' => ShellNavigator.shopTab,
    '/user/ticket' => ShellNavigator.ticketsTab,
    '/user/unlock' => ShellNavigator.unlockTab,
    _ => null,
  };

  static Widget? _pageOf(String route) => switch (route) {
    '/user/profile' => const AccountPage(),
    '/user/edit' => const EditAccountPage(),
    '/user/invite' => const InvitePage(),
    '/user/trafficlog' => const TrafficLogPage(),
    '/user/operation_logs' => const OperationLogsPage(),
    '/user/recharge' => const RechargePage(),
    '/user/balance-transactions' => const BalanceRecordsPage(),
    '/user/purchases' => const PurchasesPage(),
    '/user/kill' => const DeleteAccountPage(),
    _ => null,
  };

  static String _appRoute(String url, String base) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.hasAuthority && uri.host != Uri.tryParse(base)?.host)) {
      return '';
    }
    String path = uri.path;
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (_tabOf(path) != null || _pageOf(path) != null) {
      return path;
    }
    // 只回退一级：再往上走会把 /user/tutorial 这类没有对应页面的路径落到 /user 首页
    final List<String> parts = path.split('/');
    if (parts.length > 3) {
      final String parent = parts.take(3).join('/');
      if (_tabOf(parent) != null || _pageOf(parent) != null) {
        return parent;
      }
    }
    return '';
  }

  static bool _openInApp(BuildContext context, String route) {
    final int? tab = _tabOf(route);
    if (tab != null) {
      return ShellNavigator.openTab(context, tab);
    }
    final Widget? page = _pageOf(route);
    if (page == null) {
      return false;
    }
    final NavigatorState nav = Navigator.of(context);
    if (ModalRoute.of(context) is PopupRoute) {
      nav.pop();
    }
    nav.push(MaterialPageRoute<void>(builder: (BuildContext context) => page));
    return true;
  }
}

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
                  child: InkWell(
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
