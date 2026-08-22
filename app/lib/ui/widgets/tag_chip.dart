import 'package:flutter/material.dart';

class TagChip extends StatelessWidget {
  const TagChip({
    super.key,
    required this.label,
    this.color,
    this.icon,
    this.capsule = false,
  });

  static const double capsuleHeight = 20;

  static Widget wrap({
    String protocol = '',
    String network = '',
    String tls = '',
    String udp = '',
  }) => Row(
    spacing: 4,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      if (protocol.isNotEmpty) TagChip(label: protocol),
      if (network.isNotEmpty) TagChip(label: network),
      if (tls.isNotEmpty) TagChip(label: tls),
      if (udp.isNotEmpty) TagChip(label: udp),
    ],
  );

  final String label;
  final Color? color;
  final IconData? icon;
  final bool capsule;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color tone = color ?? scheme.onSurfaceVariant;
    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: 11, color: tone),
          SizedBox(width: capsule ? 4 : 3),
        ],
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontSize: 10,
            height: capsule ? 1 : 1.4,
            fontWeight: FontWeight.w600,
            color: tone,
            leadingDistribution: capsule ? TextLeadingDistribution.even : null,
          ),
        ),
      ],
    );

    if (capsule) {
      return SizedBox(
        height: capsuleHeight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tone.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: tone.withValues(alpha: 0.3)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Align(
              alignment: Alignment.center,
              widthFactor: 1,
              child: content,
            ),
          ),
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(icon == null ? 6 : 4, 1, 6, 1),
        child: content,
      ),
    );
  }
}
