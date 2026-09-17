import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme.dart';

class GroupDelayTestButton extends StatelessWidget {
  const GroupDelayTestButton({
    super.key,
    required this.testing,
    required this.onPressed,
    this.inMenu = false,
  });

  final bool testing;
  final VoidCallback onPressed;
  final bool inMenu;

  @override
  Widget build(BuildContext context) {
    final IconButton button = IconButton(
      tooltip: L10n.t('测试本组全部节点延迟'),
      iconSize: 16,
      visualDensity: VisualDensity.standard,
      constraints: BoxConstraints.tightFor(
        width: AppTheme.minTapTarget,
        height: AppTheme.minTapTarget,
      ),
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
    if (!inMenu) {
      return button;
    }
    return MenuItemButton(
      leadingIcon: button.icon,
      onPressed: button.onPressed,
      style: MenuItemButton.styleFrom(
        iconSize: 16,
        textStyle: Theme.of(context).textTheme.bodyMedium,
        minimumSize: Size(0, AppTheme.minTapTarget),
        visualDensity: VisualDensity.standard,
      ),
      child: SizedBox(width: 210, child: Text(button.tooltip!)),
    );
  }
}
