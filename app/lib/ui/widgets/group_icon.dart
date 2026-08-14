import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../node_labels.dart';
import '../theme.dart';
import 'icon_image.dart';
import 'user_avatar.dart';

class GroupIcon extends StatelessWidget {
  const GroupIcon({
    super.key,
    required this.url,
    required this.selectable,
    this.size = 30,
  });

  final String? url;
  final bool selectable;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double iconSize = size * 20 / 30;
    final Widget builtin = Icon(
      NodeLabels.groupIcon(selectable: selectable),
      size: iconSize,
      color: theme.colorScheme.primary,
    );

    final String? resolved = UserAvatar.resolveUrl(
      url,
      origin: AppScope.of(context).auth.siteOrigin,
    );
    if (resolved == null) {
      return SizedBox(height: size, width: size, child: Center(child: builtin));
    }

    // 面板下发的品牌图标都是按浅色背景做的，深色主题下纯黑那几个（Apple、Anthropic、
    // Cursor）与卡片底色糊在一起，垫一层浅色底板才认得出；浅色主题不需要
    final double pad = size * 3 / 30;
    return Container(
      height: size,
      width: size,
      padding: EdgeInsets.all(pad),
      decoration: theme.brightness == Brightness.dark
          ? BoxDecoration(
              color: const Color(0xFFF2F3F5),
              borderRadius: BorderRadius.circular(AppTheme.tileRadius),
            )
          : null,
      child: RemoteIcon(
        url: resolved,
        width: size - pad * 2,
        fallback: builtin,
      ),
    );
  }
}
