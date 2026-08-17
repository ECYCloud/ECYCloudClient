import 'package:flutter/material.dart';

/// 全站统一的卡片：标题行（图标 + 标题 + 右侧操作）+ 内容区。
/// 各页面自己拼 Card + Padding + Row 时高度和留白永远对不齐，统一收在这里。
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.icon,
    this.title,
    this.action,
    this.padding = const EdgeInsets.all(14),
    required this.child,
  });

  final IconData? icon;
  final String? title;
  final Widget? action;
  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? title = this.title;

    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (title != null) ...<Widget>[
              // 只保底高度：右侧动作是按钮时比标题文字高，写死高度会把按钮压扁
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 22),
                child: Row(
                  children: <Widget>[
                    if (icon != null) ...<Widget>[
                      Icon(
                        icon,
                        size: 15,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 7),
                    ],
                    Text(title, style: theme.textTheme.titleSmall),
                    const Spacer(),
                    ?action,
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

/// 「标签 + 数值」两行式指标，卡片内的通用信息单元
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.color,
  });

  final String label;
  final String value;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // 整块靠左、块内居中：Align 给的是松约束，Column 因而收到标签行的宽度，
    // 数值才能在标签下方居中。Row 必须 min，否则它撑满整格，居中就成了按整格居中
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        children: <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(
                  icon,
                  size: 12,
                  color: color ?? theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              color: color,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// 「左标签 右取值」单行式信息，用于账号等纵向罗列的字段
class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(width: 12),
          // 取值必须占满剩余宽度才能真正右对齐：换成 Spacer + Flexible 时两者
          // 各分走一半余量，短取值会停在半程上，同列各行的右边缘对不齐
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
