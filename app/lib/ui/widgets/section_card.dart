import 'package:flutter/material.dart';

import '../theme.dart';

// Material 图标画在 24 格里、有效区 20。盒边与文字行高同为 [size]，
// 字形放大 24/20 再裁进盒内，视觉才和同号中文一样大、中线对齐。
Widget matchedSectionIcon(
  IconData icon,
  double size,
  Color color, {
  String? semanticLabel,
}) {
  const double live = 24 / 20;
  return SizedBox(
    width: size,
    height: size,
    child: ClipRect(
      child: OverflowBox(
        alignment: Alignment.center,
        minWidth: size * live,
        minHeight: size * live,
        maxWidth: size * live,
        maxHeight: size * live,
        child: Icon(
          icon,
          size: size * live,
          color: color,
          semanticLabel: semanticLabel,
        ),
      ),
    ),
  );
}

TextStyle _sectionTitleStyle(ThemeData theme) {
  return theme.textTheme.titleSmall!.copyWith(
    fontSize: AppTheme.sectionTitleSize,
    height: 1,
    leadingDistribution: TextLeadingDistribution.even,
  );
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.icon,
    this.title,
    this.titleTrailing,
    this.action,
    this.padding = const EdgeInsets.fromLTRB(24, 20, 24, 20),
    required this.child,
  });

  final IconData? icon;
  final String? title;
  final Widget? titleTrailing;
  final Widget? action;
  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? title = this.title;
    final double titleSize = AppTheme.sectionTitleSize;
    final TextStyle titleStyle = _sectionTitleStyle(theme);

    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (title != null) ...<Widget>[
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 22),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) => Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      if (icon != null) ...<Widget>[
                        matchedSectionIcon(
                          icon!,
                          titleSize,
                          theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 7),
                      ],
                      Expanded(
                        child: Row(
                          children: <Widget>[
                            Flexible(child: Text(title, style: titleStyle)),
                            ?titleTrailing,
                          ],
                        ),
                      ),
                      if (action != null)
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * 0.65,
                          ),
                          child: action!,
                        ),
                    ],
                  ),
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

class SectionTitle extends StatelessWidget {
  const SectionTitle({super.key, required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double titleSize = AppTheme.sectionTitleSize;

    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 7),
      child: Row(
        children: <Widget>[
          matchedSectionIcon(icon, titleSize, theme.colorScheme.onSurface),
          const SizedBox(width: 6),
          Text(title, style: _sectionTitleStyle(theme)),
        ],
      ),
    );
  }
}

class Section extends StatelessWidget {
  const Section({
    super.key,
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SectionTitle(icon: icon, title: title),
        Card(
          child: Column(
            children: <Widget>[
              for (int i = 0; i < children.length; i++) ...<Widget>[
                if (i > 0) const Divider(),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

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
    final TextStyle labelStyle = theme.textTheme.bodySmall!.copyWith(
      height: 1,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final double labelSize = labelStyle.fontSize!;

    // 整块靠左、块内居中：Align 给的是松约束，Column 因而收到标签行的宽度，
    // 数值才能在标签下方居中。Row 必须 min，否则它撑满整格，居中就成了按整格居中
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        children: <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                matchedSectionIcon(
                  icon!,
                  labelSize,
                  color ?? theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: labelStyle,
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

class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2.5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * 0.65,
              ),
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
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
      ),
    );
  }
}










