import 'package:flutter/material.dart';

import '../theme.dart';
import '../../l10n/l10n.dart';

class DelayBadge extends StatelessWidget {
  const DelayBadge({
    super.key,
    required this.delay,
    required this.testing,
    required this.unreachable,
    required this.onTest,
  });

  final int delay;
  final bool testing;
  final bool unreachable;
  final VoidCallback onTest;

  static Color colorOf(int delay) => switch (delay) {
    < 200 => AppTheme.success,
    < 500 => AppTheme.warning,
    _ => AppTheme.danger,
  };

  static Widget? label(int delay) {
    if (delay <= 0) {
      return null;
    }
    return Builder(
      builder: (BuildContext context) => _text(context, '$delay', colorOf(delay)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (testing) {
      return const SizedBox(
        height: 24,
        width: 34,
        child: Center(
          child: SizedBox(
            height: 12,
            width: 12,
            child: CircularProgressIndicator(strokeWidth: 1.6),
          ),
        ),
      );
    }

    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget content = switch ((delay, unreachable)) {
      (> 0, _) => _text(context, '$delay', colorOf(delay)),
      (_, true) => _text(context, L10n.t('超时'), AppTheme.danger),
      _ => Icon(Icons.bolt_outlined, size: 13, color: scheme.outline),
    };

    return Tooltip(
      message: L10n.t('测试该节点延迟'),
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTest,
        borderRadius: BorderRadius.circular(6),
        mouseCursor: SystemMouseCursors.click,
        child: SizedBox(height: 24, width: 34, child: Center(child: content)),
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
