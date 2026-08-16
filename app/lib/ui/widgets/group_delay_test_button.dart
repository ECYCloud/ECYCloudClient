import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';

class GroupDelayTestButton extends StatelessWidget {
  const GroupDelayTestButton({
    super.key,
    required this.testing,
    required this.onPressed,
  });

  final bool testing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: L10n.t('测试本组全部节点延迟'),
    iconSize: 16,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints.tightFor(width: 28, height: 28),
    padding: EdgeInsets.zero,
    icon: testing
        ? const SizedBox(
            height: 14,
            width: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.bolt_outlined),
    onPressed: testing ? null : onPressed,
  );
}
