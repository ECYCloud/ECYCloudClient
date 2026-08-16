import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

/// 刷新是个瞬时动作，没有动画时用户分不清点没点上；
/// 至少转满一圈再停，避免请求过快时只闪一下。
/// [label] 为空时渲染成纯图标按钮，否则渲染成带文字的按钮；
/// [RefreshButton.tile] 渲染成整行可点的设置项，右侧图标只作反馈。
class RefreshButton extends StatefulWidget {
  const RefreshButton({
    super.key,
    required this.onRefresh,
    this.tooltip,
    this.label,
    this.iconSize = 20,
    this.color,
  }) : title = null,
       subtitle = null,
       action = null;

  const RefreshButton.tile({
    super.key,
    required this.onRefresh,
    required this.title,
    this.subtitle,
    this.action,
    this.tooltip,
  }) : label = null,
       iconSize = 20,
       color = null;

  final Future<void> Function() onRefresh;
  final String? tooltip;
  final String? label;
  final double iconSize;
  final Color? color;
  final String? title;
  final String? subtitle;
  final Widget? action;

  @override
  State<RefreshButton> createState() => _RefreshButtonState();
}

class _RefreshButtonState extends State<RefreshButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    unawaited(_controller.repeat());
    try {
      await widget.onRefresh();
    } finally {
      await _controller
          .forward(from: _controller.value)
          .orCancel
          .catchError((Object _) => null);
      _controller.stop();
      _controller.value = 0;
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget icon = RotationTransition(
      turns: _controller,
      child: Icon(Icons.refresh, size: widget.iconSize, color: widget.color),
    );
    // 不置灰：禁用态的按钮会把鼠标指针换回箭头，看着像功能坏了。
    // 重复点击由 _run 自身挡掉
    void onPressed() => unawaited(_run());
    final Widget iconButton = IconButton(
      tooltip: widget.tooltip,
      icon: icon,
      padding: EdgeInsets.zero,
      visualDensity: AppTheme.iconActionDensity,
      constraints: AppTheme.iconActionBox(),
      onPressed: onPressed,
    );

    final String? title = widget.title;
    if (title != null) {
      final Widget? action = widget.action;
      final String? subtitle = widget.subtitle;
      // ListTile 只把 trailing 整体靠右，图标居中于按钮盒子时右边缘会比同列的
      // chevron 内缩，同一张卡里就参差；把内边距全留在左侧让图标贴住右边缘
      final Widget trailing = IconButton(
        tooltip: widget.tooltip,
        icon: icon,
        padding: AppTheme.iconActionFlushRightPadding,
        visualDensity: AppTheme.iconActionDensity,
        constraints: AppTheme.iconActionBox(),
        onPressed: onPressed,
      );
      return ListTile(
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: action == null
            ? trailing
            : Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: <Widget>[action, trailing],
              ),
        onTap: onPressed,
      );
    }

    final String? label = widget.label;
    if (label == null) {
      return iconButton;
    }

    return TextButton.icon(
      onPressed: onPressed,
      icon: icon,
      label: Text(label),
    );
  }
}
