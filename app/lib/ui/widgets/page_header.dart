import 'package:flutter/material.dart';

import '../theme.dart';
import 'user_avatar.dart';

/// 与侧栏连接状态图标垂直居中对齐。
///
/// NavigationRail 默认上下各约 8px 内边距，其 leading 里的状态图标为 32×32；
/// 标题放在等高盒子内居中，右侧操作区可更高，整行按中线对齐。
///
/// 左右外边距同为 [edge]；操作按钮之间用 [actionGap]；头像与操作区再隔开
/// [edge]，避免与刷新等贴死。
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.actions,
    this.showUserAvatar = false,
    this.showBackButton = false,
  });

  final String title;
  final List<Widget>? actions;
  final bool showUserAvatar;
  final bool showBackButton;

  /// 与 [UserAvatarButton.edge] / AppBar `actionsPadding` 一致。
  static const double edge = UserAvatarButton.edge;

  /// 标题行内操作按钮间距（余额 / 刷新 / 创建等）。
  static const double actionGap = 8;

  static const double _railPaddingTop = 8;
  static const double _brandSize = 32;

  static double get _actionIconInset =>
      (AppTheme.iconActionExtent - AppTheme.iconActionIconSize) / 2;

  @override
  Widget build(BuildContext context) {
    final double left = showBackButton ? edge - _actionIconInset : edge;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(left, _railPaddingTop, edge, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              if (showBackButton) ...<Widget>[
                IconButton(
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: const BackButtonIcon(),
                  iconSize: AppTheme.iconActionIconSize,
                  padding: EdgeInsets.zero,
                  visualDensity: AppTheme.iconActionDensity,
                  constraints: AppTheme.iconActionBox(),
                  onPressed: () {
                    Navigator.maybePop(context);
                  },
                ),
                const SizedBox(width: actionGap),
              ],
              SizedBox(
                height: _brandSize,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              const Spacer(),
              if (actions != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: actions!,
                ),
              if (showUserAvatar) ...<Widget>[
                const SizedBox(width: edge),
                const UserAvatarButton(),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}
