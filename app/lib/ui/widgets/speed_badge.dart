import 'package:flutter/material.dart';

import '../format.dart';
import '../theme.dart';
import '../../l10n/l10n.dart';

class SpeedBadge extends StatelessWidget {
  const SpeedBadge({
    super.key,
    required this.bytesPerSecond,
    required this.testing,
    required this.failed,
    required this.onTest,
  });

  final int bytesPerSecond;
  final bool testing;
  final bool failed;
  final VoidCallback onTest;

  static Color colorOf(int bytesPerSecond) => switch (bytesPerSecond) {
    >= 5 * 1024 * 1024 => AppTheme.success,
    >= 1 * 1024 * 1024 => AppTheme.warning,
    _ => AppTheme.danger,
  };

  @override
  Widget build(BuildContext context) {
    if (testing) {
      return SizedBox(
        height: AppTheme.minTapTarget,
        width: AppTheme.minTapTarget,
        child: const Center(
          child: SizedBox(
            height: 12,
            width: 12,
            child: CircularProgressIndicator(strokeWidth: 1.6),
          ),
        ),
      );
    }

    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget content = switch ((bytesPerSecond, failed)) {
      (> 0, _) => _text(
        context,
        Format.speedSi(bytesPerSecond),
        colorOf(bytesPerSecond),
      ),
      (_, true) => _text(context, L10n.t('失败'), AppTheme.danger),
      _ => Icon(Icons.speed, size: 16, color: scheme.onSurfaceVariant),
    };

    return Tooltip(
      message: L10n.t('测试该节点网速'),
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTest,
          borderRadius: BorderRadius.circular(AppTheme.minTapTarget / 2),
          mouseCursor: SystemMouseCursors.click,
          hoverColor: scheme.primary.withValues(alpha: 0.12),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: AppTheme.minTapTarget,
              minHeight: AppTheme.minTapTarget,
              maxHeight: AppTheme.minTapTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Align(widthFactor: 1, heightFactor: 1, child: content),
            ),
          ),
        ),
      ),
    );
  }

  static Widget _text(BuildContext context, String text, Color color) => Text(
    text,
    style: Theme.of(context).textTheme.labelMedium?.copyWith(
      fontSize: 11,
      height: 1,
      color: color,
      fontWeight: FontWeight.w600,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    ),
  );
}
