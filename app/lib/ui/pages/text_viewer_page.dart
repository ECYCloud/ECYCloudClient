import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/text_line_index.dart';
import '../../l10n/l10n.dart';
import '../theme.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/overlay_scroll_view.dart';

class TextViewerPage extends StatefulWidget {
  const TextViewerPage({
    required this.title,
    required this.load,
    this.subtitle,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Future<String> Function() load;

  @override
  State<TextViewerPage> createState() => _TextViewerPageState();
}

class _TextViewerPageState extends State<TextViewerPage> {
  late final Future<String> _future = widget.load();
  late final Future<TextLineIndex> _lines = _future.then(TextLineIndex.build);
  final ScrollController _scroll = ScrollController();
  final ScrollController _horizontal = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  static double _textWidth(
    String text,
    TextStyle? style,
    TextScaler scaler,
    TextDirection direction,
  ) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final double width = painter.width;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? caption = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return AppScaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: <Widget>[
          FutureBuilder<String>(
            future: _future,
            builder: (BuildContext context, AsyncSnapshot<String> snap) {
              final String? text = snap.data;
              if (text == null || text.isEmpty) {
                return const SizedBox.shrink();
              }
              return IconButton(
                tooltip: L10n.t('复制全部'),
                icon: const Icon(Icons.copy_all_outlined),
                onPressed: () => Clipboard.setData(ClipboardData(text: text)),
              );
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: <Widget>[
                Expanded(child: Text(widget.subtitle ?? '', style: caption)),
                FutureBuilder<TextLineIndex>(
                  future: _lines,
                  builder:
                      (
                        BuildContext context,
                        AsyncSnapshot<TextLineIndex> snap,
                      ) {
                        final TextLineIndex? lines = snap.data;
                        return lines == null || lines.length == 0
                            ? const SizedBox.shrink()
                            : Text(
                                L10n.t('共 {0} 行', <Object>[lines.length]),
                                style: caption,
                              );
                      },
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<TextLineIndex>(
              future: _lines,
              builder:
                  (BuildContext context, AsyncSnapshot<TextLineIndex> snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snap.hasError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            '${snap.error}',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                      );
                    }
                    final TextLineIndex? lines = snap.data;
                    if (lines == null || lines.length == 0) {
                      return Center(
                        child: Text(
                          L10n.t('文件为空或不存在'),
                          style: theme.textTheme.bodyLarge,
                        ),
                      );
                    }
                    final TextStyle? style = theme.textTheme.bodySmall
                        ?.copyWith(
                          fontFamily: AppTheme.monoFontFamily,
                          fontSize: 12,
                          height: 1.45,
                        );
                    final TextStyle? numberStyle = style?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    );
                    final StrutStyle strut = StrutStyle(
                      fontFamily: AppTheme.monoFontFamily,
                      fontSize: 12,
                      height: 1.45,
                      forceStrutHeight: true,
                    );
                    final TextScaler scaler = MediaQuery.textScalerOf(context);
                    final TextDirection direction = Directionality.of(context);
                    final double numberWidth = _textWidth(
                      '0' * '${lines.length}'.length,
                      numberStyle,
                      scaler,
                      direction,
                    );
                    double textWidth = 0;
                    for (final int line in lines.widest) {
                      textWidth = math.max(
                        textWidth,
                        _textWidth(lines[line], style, scaler, direction),
                      );
                    }
                    const double numberGap = 12;
                    final double rowWidth =
                        numberWidth + numberGap + textWidth.ceilToDouble() + 1;
                    // 整份文件一次排版或逐行量高都会卡住界面：行高固定，只排版可见行，不折行改为横向滚动
                    return LayoutBuilder(
                      builder: (BuildContext context, BoxConstraints box) {
                        final Widget rows = ScrollConfiguration(
                          behavior: ScrollConfiguration.of(context)
                              .copyWith(scrollbars: false),
                          child: CustomScrollView(
                            controller: _scroll,
                            slivers: <Widget>[
                              SliverPadding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppTheme.overlayScrollGutter,
                                ),
                                sliver: SliverFixedExtentList(
                                  itemExtent: scaler.scale(12) * 1.45,
                                  delegate: SliverChildBuilderDelegate(
                                    (BuildContext context, int index) => Row(
                                      children: <Widget>[
                                        SizedBox(
                                          width: numberWidth,
                                          child: SelectionContainer.disabled(
                                            child: Text(
                                              '${index + 1}',
                                              textAlign: TextAlign.right,
                                              style: numberStyle,
                                              strutStyle: strut,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: numberGap),
                                        Expanded(
                                          child: Text(
                                            lines[index],
                                            style: style,
                                            strutStyle: strut,
                                            softWrap: false,
                                            maxLines: 1,
                                            overflow: TextOverflow.clip,
                                          ),
                                        ),
                                      ],
                                    ),
                                    childCount: lines.length,
                                    addAutomaticKeepAlives: false,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                        return Scrollbar(
                          controller: _scroll,
                          notificationPredicate: (
                            ScrollNotification notification,
                          ) => notification.depth == 1,
                          child: OverlayScrollView(
                            controller: _horizontal,
                            scrollDirection: Axis.horizontal,
                            padding: EdgeInsets.zero,
                            child: SizedBox(
                              width: math.max(
                                box.maxWidth,
                                rowWidth + AppTheme.overlayScrollGutter * 2,
                              ),
                              height: math.max(
                                0,
                                box.maxHeight - AppTheme.overlayScrollGutter,
                              ),
                              child: rows,
                            ),
                          ),
                        );
                      },
                    );
                  },
            ),
          ),
        ],
      ),
    );
  }
}
