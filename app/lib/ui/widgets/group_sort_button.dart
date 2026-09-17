import 'package:flutter/material.dart';

import '../../domain/nodes/node_group_sort.dart';
import '../../l10n/l10n.dart';
import '../theme.dart';

class GroupSortButton extends StatelessWidget {
  const GroupSortButton({
    super.key,
    required this.mode,
    required this.onPressed,
    this.inMenu = false,
  });

  final NodeGroupSort mode;
  final VoidCallback onPressed;
  final bool inMenu;

  @override
  Widget build(BuildContext context) {
    final IconButton button = IconButton(
      tooltip: switch (mode) {
        NodeGroupSort.name => L10n.t('目前按名称正序排列，点击切换为最低延迟'),
        NodeGroupSort.latency => L10n.t('目前按最低延迟排列，点击切换为最高网速'),
        NodeGroupSort.speed => L10n.t('目前按最高网速排列，点击切换为名称正序'),
      },
      iconSize: 16,
      visualDensity: VisualDensity.standard,
      constraints: BoxConstraints.tightFor(
        width: AppTheme.minTapTarget,
        height: AppTheme.minTapTarget,
      ),
      padding: EdgeInsets.zero,
      icon: Icon(switch (mode) {
        NodeGroupSort.name => Icons.sort_by_alpha,
        NodeGroupSort.latency => Icons.timer_outlined,
        NodeGroupSort.speed => Icons.trending_up,
      }),
      onPressed: onPressed,
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
      child: SizedBox(
        width: 210,
        child: Text(switch (mode) {
          NodeGroupSort.name => L10n.t('按最低延迟排序'),
          NodeGroupSort.latency => L10n.t('按最高网速排序'),
          NodeGroupSort.speed => L10n.t('按名称排序'),
        }),
      ),
    );
  }
}
