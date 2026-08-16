import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/announcement.dart';
import '../../state/announcement_controller.dart';
import 'rich_html_view.dart';
import '../../l10n/l10n.dart';

Future<void> showAnnouncementPopup(
  BuildContext context, {
  required Announcement announcement,
  required AnnouncementController controller,
  bool dismissible = true,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: dismissible,
    builder: (BuildContext context) => AlertDialog(
      title: Text(announcement.title),
      content: SingleChildScrollView(
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
  // 旧逻辑 await refresh()：点铃铛先等面板 RTT（约 1–2s）才弹窗，体感卡顿。
  // 有缓存立刻弹；无缓存先出加载态；刷新一律后台进行。
  if (!controller.busy) {
    unawaited(controller.refresh());
  }

  await showDialog<void>(
    context: context,
    builder: (BuildContext context) => ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, _) {
        final List<Announcement> items = controller.items;
        // 仅在「正在拉且尚无数据」时转圈；失败/429/确实无公告要落到文案，
        // 不能用 !loaded 单独判断，否则会永远停在加载态。
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
                  (controller.loaded ? L10n.t('暂无公告') : L10n.t('暂时无法获取公告，请稍后重试')),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(L10n.t('关闭')),
              ),
            ],
          );
        }
        return _AnnouncementBrowser(items: items);
      },
    ),
  );
  controller.markSeen();
}

class _AnnouncementBrowser extends StatefulWidget {
  const _AnnouncementBrowser({required this.items});

  final List<Announcement> items;

  @override
  State<_AnnouncementBrowser> createState() => _AnnouncementBrowserState();
}

class _AnnouncementBrowserState extends State<_AnnouncementBrowser> {
  int _index = 0;

  @override
  void didUpdateWidget(covariant _AnnouncementBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
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
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: SingleChildScrollView(
              child: RichHtmlView(current.content),
            ),
          ),
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
