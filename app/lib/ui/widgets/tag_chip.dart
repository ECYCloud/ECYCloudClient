import 'package:flutter/material.dart';

/// 小号信息标签：协议、分组类型、连接状态等只读标记统一用它，
/// 避免每处各写一套 Container + BoxDecoration。
class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.label, this.color, this.icon});

  final String label;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color tone = color ?? scheme.onSurfaceVariant;

    return Container(
      padding: EdgeInsets.fromLTRB(icon == null ? 6 : 4, 1, 6, 1),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 11, color: tone),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 10,
              height: 1.4,
              fontWeight: FontWeight.w600,
              color: tone,
            ),
          ),
        ],
      ),
    );
  }
}
