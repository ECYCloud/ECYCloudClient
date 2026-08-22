import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

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
       iconSize = 24,
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
    void onPressed() => unawaited(_run());
    final Widget iconButton = IconButton(
      tooltip: widget.tooltip,
      icon: icon,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.standard,
      constraints: BoxConstraints.tightFor(
        width: AppTheme.minTapTarget,
        height: AppTheme.minTapTarget,
      ),
      onPressed: onPressed,
    );

    final String? title = widget.title;
    if (title != null) {
      final Widget? action = widget.action;
      final String? subtitle = widget.subtitle;
      return ListTile(
        contentPadding: EdgeInsetsDirectional.only(
          start: 16,
          end: AppTheme.trailingIconButtonInset(widget.iconSize),
        ),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: action == null
            ? iconButton
            : Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: <Widget>[action, iconButton],
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
