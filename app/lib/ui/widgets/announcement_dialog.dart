import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/announcement.dart';
import '../../state/announcement_controller.dart';
import 'clipped_scroll_body.dart';
import 'overlay_scroll_view.dart';
import 'rich_html_view.dart';
import '../../l10n/l10n.dart';

Future<void> showAnnouncementPopup(
  BuildContext context, {
  required Announcement announcement,
  required AnnouncementController controller,
  bool dismissible = true,
}) {
  controller.markAnnouncementSeen(announcement);
  return showDialog<void>(
    context: context,
    barrierDismissible: dismissible,
    builder: (BuildContext context) => AlertDialog(
      title: Text(announcement.title),
      content: OverlayScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (announcement.id != 1 && announcement.date.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  announcement.date,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            RichHtmlView(announcement.content),
          ],
        ),
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () {
            controller.dismissPopup(announcement);
            Navigator.of(context).pop();
          },
          child: Text(L10n.t('我知道了')),
        ),
      ],
    ),
  );
}

Future<void> showAnnouncementBrowser(
  BuildContext context, {
  required AnnouncementController controller,
}) async {
  if (!controller.busy) {
    unawaited(controller.refresh());
  }

  await showDialog<void>(
    context: context,
    builder: (BuildContext context) => ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, _) {
        final List<Announcement> items = controller.items;
        if (items.isEmpty && !controller.loaded && controller.busy) {
          return AlertDialog(
            title: Text(L10n.t('网站公告')),
            content: const SizedBox(
              height: 96,
              child: Center(child: CircularProgressIndicator()),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(L10n.t('关闭')),
              ),
            ],
          );
        }
        if (items.isEmpty) {
          return AlertDialog(
            title: Text(L10n.t('网站公告')),
            content: Text(
              controller.error ??
                  (controller.loaded
                      ? L10n.t('暂无公告')
                      : L10n.t('暂时无法获取公告，请稍后重试')),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(L10n.t('关闭')),
              ),
            ],
          );
        }
        final int index = controller.openIndex.clamp(0, items.length - 1);
        return _AnnouncementBrowser(
          key: ValueKey<int>(items[index].id),
          items: items,
          initialIndex: index,
        );
      },
    ),
  );
  controller.markSeen();
}

class _AnnouncementBrowser extends StatefulWidget {
  const _AnnouncementBrowser({
    super.key,
    required this.items,
    this.initialIndex = 0,
  });

  final List<Announcement> items;
  final int initialIndex;

  @override
  State<_AnnouncementBrowser> createState() => _AnnouncementBrowserState();
}

class _AnnouncementBrowserState extends State<_AnnouncementBrowser> {
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.items.length - 1);
  }

  @override
  void didUpdateWidget(covariant _AnnouncementBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialIndex != oldWidget.initialIndex) {
      _index = widget.initialIndex.clamp(
        0,
        widget.items.isEmpty ? 0 : widget.items.length - 1,
      );
      return;
    }
    if (_index >= widget.items.length) {
      _index = widget.items.isEmpty ? 0 : widget.items.length - 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Announcement current = widget.items[_index];
    final bool multi = widget.items.length > 1;

    return AlertDialog(
      title: Text(current.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (current.id != 1 && current.date.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                current.date,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ClippedScrollBody(child: RichHtmlView(current.content)),
          if (multi) ...<Widget>[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                TextButton(
                  onPressed: () => setState(() {
                    _index =
                        (_index - 1 + widget.items.length) %
                        widget.items.length;
                  }),
                  child: Text(L10n.t('上一条')),
                ),
                Text(
                  '${_index + 1} / ${widget.items.length}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _index = (_index + 1) % widget.items.length;
                  }),
                  child: Text(L10n.t('下一条')),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L10n.t('关闭')),
        ),
      ],
    );
  }
}
