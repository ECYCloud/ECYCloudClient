import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../data/models/user_profile.dart';
import '../../state/auth_controller.dart';
import '../../state/connection_controller.dart';
import '../app_scope.dart';
import '../pages/account_page.dart';
import '../theme.dart';
import '../../l10n/l10n.dart';

class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, required this.profile, this.radius = 18});

  final UserProfile? profile;
  final double radius;

  static String? resolveUrl(String? avatar, {required String origin}) {
    if (avatar == null || avatar.isEmpty) {
      return null;
    }
    if (avatar.startsWith('data:') ||
        avatar.startsWith('http://') ||
        avatar.startsWith('https://')) {
      return avatar;
    }
    if (avatar.startsWith('/')) {
      if (origin.isEmpty) {
        return null;
      }
      return Uri.parse(origin).resolve(avatar).toString();
    }
    return avatar;
  }

  static Color? _svgFillColor(String svg) {
    final Match? hsl = RegExp(
      r'''fill=["']hsl\((\d+(?:\.\d+)?),\s*([\d.]+)%,\s*([\d.]+)%\)["']''',
    ).firstMatch(svg);
    if (hsl != null) {
      return HSLColor.fromAHSL(
        1,
        double.parse(hsl.group(1)!),
        double.parse(hsl.group(2)!) / 100,
        double.parse(hsl.group(3)!) / 100,
      ).toColor();
    }
    final Match? hex = RegExp(
      r'''fill=["']#([0-9A-Fa-f]{6})["']''',
    ).firstMatch(svg);
    if (hex != null) {
      return Color(int.parse(hex.group(1)!, radix: 16) | 0xFF000000);
    }
    return null;
  }

  static bool _isSvgUrl(String url) {
    final String path = Uri.tryParse(url)?.path ?? url;
    return path.toLowerCase().endsWith('.svg');
  }

  @override
  Widget build(BuildContext context) {
    final UserProfile? user = profile;
    final String letter = user == null || user.displayName.isEmpty
        ? '?'
        : user.displayName.substring(0, 1).toUpperCase();
    final TextStyle? letterStyle = Theme.of(
      context,
    ).textTheme.labelMedium?.copyWith(fontSize: radius * 0.9);
    final Widget fallback = CircleAvatar(
      radius: radius,
      child: Text(letter, style: letterStyle),
    );

    final String? url = resolveUrl(
      user?.avatar,
      origin: AppScope.of(context).auth.siteOrigin,
    );
    if (url == null) {
      return fallback;
    }

    // flutter_svg 不完整支持 SVG <text> 的 dy，面板字母头像须用 Flutter 文本绘制
    if (url.startsWith('data:image/svg+xml;base64,')) {
      try {
        final String svg = utf8.decode(base64Decode(url.split(',').last));
        final Color? bg = _svgFillColor(svg);
        if (bg != null) {
          return CircleAvatar(
            radius: radius,
            backgroundColor: bg,
            child: Text(
              letter,
              style: letterStyle?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }
      } on Object {
        // fall through
      }
      return fallback;
    }

    if (url.startsWith('data:')) {
      return fallback;
    }

    if (_isSvgUrl(url)) {
      return ClipOval(
        child: SvgPicture.network(
          url,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          placeholderBuilder: (_) => fallback,
          errorBuilder: (_, _, _) => fallback,
        ),
      );
    }

    return ClipOval(
      child: Image.network(
        url,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

class UserAvatarButton extends StatelessWidget {
  const UserAvatarButton({super.key, this.radius = 18, this.leadingGap = 0});

  static const double edge = 14;

  static const double _menuWidth = 136;
  static const double _itemHeight = 32;

  final double radius;
  final double leadingGap;

  @override
  Widget build(BuildContext context) {
    final AppScope scope = AppScope.of(context);
    final AuthController auth = scope.auth;
    final ConnectionController connection = scope.connection;
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle style = theme.textTheme.bodyLarge!.copyWith(
      fontSize: AppTheme.navLabelSize,
      fontWeight: FontWeight.w400,
    );
    final BorderRadius menuRadius = BorderRadius.circular(AppTheme.menuRadius);
    // MenuAnchor 的 position 是相对锚点盒子左上角的偏移（_MenuLayout 按
    // position + anchorRect.topLeft 落位），触控端盒子被放大到 minTapTarget，
    // 按头像直径算菜单会落进盒子里压住头像
    final double anchorSize = AppTheme.isTouch
        ? AppTheme.minTapTarget
        : radius * 2;
    final bool onAccount =
        context.findAncestorWidgetOfExactType<AccountPage>() != null;

    return ListenableBuilder(
      listenable: auth,
      builder: (BuildContext context, _) {
        final Widget avatar = UserAvatar(profile: auth.profile, radius: radius);
        final Widget button = MenuAnchor(
          crossAxisUnconstrained: false,
          clipBehavior: Clip.antiAlias,
          style: MenuStyle(
            alignment: AlignmentDirectional.bottomEnd,
            padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.zero),
            minimumSize: const WidgetStatePropertyAll<Size>(
              Size(_menuWidth, _itemHeight * 2),
            ),
            maximumSize: const WidgetStatePropertyAll<Size>(
              Size(_menuWidth, _itemHeight * 2),
            ),
            shape: WidgetStatePropertyAll<OutlinedBorder>(
              RoundedRectangleBorder(borderRadius: menuRadius),
            ),
          ),
          menuChildren: <Widget>[
            _HoverFillMenuItem(
              itemRadius: BorderRadius.only(
                topLeft: menuRadius.topLeft,
                topRight: menuRadius.topRight,
              ),
              style: style,
              color: scheme.onSurface,
              icon: Icons.badge_outlined,
              selectedIcon: Icons.badge,
              label: L10n.t('账户信息'),
              onPressed: () {
                if (onAccount) {
                  return;
                }
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (BuildContext context) => const AccountPage(),
                  ),
                );
              },
            ),
            _HoverFillMenuItem(
              itemRadius: BorderRadius.only(
                bottomLeft: menuRadius.bottomLeft,
                bottomRight: menuRadius.bottomRight,
              ),
              style: style,
              color: scheme.error,
              icon: Icons.logout_outlined,
              selectedIcon: Icons.logout,
              label: L10n.t('退出登录'),
              onPressed: () => unawaited(_logout(context, auth, connection)),
            ),
          ],
          builder:
              (BuildContext context, MenuController controller, Widget? child) {
                return Tooltip(
                  message: L10n.t('账户信息'),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () {
                      if (controller.isOpen) {
                        controller.close();
                      } else {
                        controller.open(
                          position: Offset(
                            anchorSize - _menuWidth,
                            anchorSize + 4,
                          ),
                        );
                      }
                    },
                    child: SizedBox(
                      width: anchorSize,
                      height: anchorSize,
                      child: Center(child: avatar),
                    ),
                  ),
                );
              },
        );
        if (leadingGap <= 0) {
          return button;
        }
        return Padding(
          padding: EdgeInsets.only(left: leadingGap),
          child: button,
        );
      },
    );
  }
}

class _HoverFillMenuItem extends StatefulWidget {
  const _HoverFillMenuItem({
    required this.itemRadius,
    required this.style,
    required this.color,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.onPressed,
  });

  final BorderRadius itemRadius;
  final TextStyle style;
  final Color color;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final VoidCallback onPressed;

  @override
  State<_HoverFillMenuItem> createState() => _HoverFillMenuItemState();
}

class _HoverFillMenuItemState extends State<_HoverFillMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: UserAvatarButton._menuWidth,
      height: UserAvatarButton._itemHeight,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: MenuItemButton(
          onPressed: widget.onPressed,
          style: MenuItemButton.styleFrom(
            minimumSize: const Size(
              UserAvatarButton._menuWidth,
              UserAvatarButton._itemHeight,
            ),
            fixedSize: const Size(
              UserAvatarButton._menuWidth,
              UserAvatarButton._itemHeight,
            ),
            maximumSize: const Size(
              UserAvatarButton._menuWidth,
              UserAvatarButton._itemHeight,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(borderRadius: widget.itemRadius),
            textStyle: widget.style,
            foregroundColor: widget.color,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                _hovered ? widget.selectedIcon : widget.icon,
                size: 16,
                color: widget.color,
              ),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: widget.style.copyWith(color: widget.color),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _logout(
  BuildContext context,
  AuthController auth,
  ConnectionController connection,
) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(L10n.t('退出登录')),
      content: Text(L10n.t('退出后将断开连接并清除本机保存的登录凭据。')),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(L10n.t('退出')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(L10n.t('取消')),
        ),
      ],
    ),
  );

  if (confirmed != true) {
    return;
  }

  await connection.disconnect();
  await auth.logout();
  if (context.mounted) {
    Navigator.of(context).popUntil((Route<dynamic> route) => route.isFirst);
  }
}
