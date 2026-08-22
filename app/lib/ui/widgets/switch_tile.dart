import 'package:flutter/material.dart';

import '../theme.dart';

// Switch 轨道尺寸 Material 写死，SwitchListTile 不能换内部开关
class SwitchTile extends StatelessWidget {
  const SwitchTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.icon,
    this.contentPadding,
    this.onSettings,
    this.settingsTooltip,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final IconData? icon;
  final EdgeInsetsGeometry? contentPadding;
  final VoidCallback? onSettings;
  final String? settingsTooltip;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<bool>? onChanged = this.onChanged;
    final VoidCallback? onSettings = this.onSettings;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return ListTile(
      contentPadding: contentPadding,
      onTap: onChanged == null ? null : () => onChanged(!value),
      leading: icon == null
          ? null
          : Icon(
              icon,
              size: 18,
              color: value ? scheme.primary : scheme.onSurfaceVariant,
            ),
      minLeadingWidth: 18,
      horizontalTitleGap: 10,
      title: onSettings == null
          ? Text(title)
          : Row(
              children: <Widget>[
                Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
                IconButton(
                  tooltip: settingsTooltip,
                  icon: Icon(
                    Icons.settings_outlined,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                  visualDensity: VisualDensity.standard,
                  constraints: BoxConstraints.tightFor(
                    width: AppTheme.minTapTarget,
                    height: AppTheme.minTapTarget,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: onSettings,
                ),
              ],
            ),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Focus(
        canRequestFocus: false,
        descendantsAreFocusable: false,
        child: Transform.scale(
          scale: AppTheme.switchScale,
          alignment: Alignment.centerRight,
          child: Switch(value: value, onChanged: onChanged),
        ),
      ),
    );
  }
}
