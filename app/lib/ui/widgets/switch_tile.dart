import 'package:flutter/material.dart';

import '../theme.dart';

/// 带说明文字的开关行。开关按 [AppTheme.switchScale] 缩小，
/// Switch 的轨道尺寸在 Material 里写死、主题无法调整，只能整体缩放，
/// 而 [SwitchListTile] 不允许替换内部的开关，故自行拼装。
///
/// 与 [SwitchListTile] 的区别：只有开关本体可点，点标题不会误触发。
class SwitchTile extends StatelessWidget {
  const SwitchTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.icon,
    this.contentPadding,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final IconData? icon;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<bool>? onChanged = this.onChanged;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return ListTile(
      contentPadding: contentPadding,
      leading: icon == null
          ? null
          : Icon(
              icon,
              size: 18,
              color: value ? scheme.primary : scheme.onSurfaceVariant,
            ),
      minLeadingWidth: 18,
      horizontalTitleGap: 10,
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Transform.scale(
        scale: AppTheme.switchScale,
        alignment: Alignment.centerRight,
        child: Switch(value: value, onChanged: onChanged),
      ),
    );
  }
}
