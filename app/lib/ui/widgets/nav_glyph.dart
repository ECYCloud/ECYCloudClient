import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class NavGlyph extends StatelessWidget {
  const NavGlyph(
    this.icon, {
    super.key,
    this.filled = false,
    this.size,
    this.color,
  });

  final IconData icon;
  final bool filled;
  final double? size;
  final Color? color;

  static bool _unlock(IconData icon) =>
      icon == Icons.lock_open || icon == Icons.lock_open_outlined;

  @override
  Widget build(BuildContext context) {
    final IconThemeData theme = IconTheme.of(context);
    final double size = this.size ?? theme.size ?? 24;
    final Color color =
        this.color ?? theme.color ?? Theme.of(context).colorScheme.onSurface;
    if (_unlock(icon)) {
      return SvgPicture.string(
        filled ? _lockOpenRightFilled : _lockOpenRightOutline,
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      );
    }
    return Icon(icon, size: size, color: color);
  }
}

// 网站 sprite.svg#lock_open_right 原 path 是线框；去掉盒身那一笔后外轮廓会填实。
const String _lockOpenRightOutline =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M240-160h480v-400H240v400Zm296.5-143.5Q560-327 560-360t-23.5-56.5Q513-440 480-440t-56.5 23.5Q400-393 400-360t23.5 56.5Q447-280 480-280t56.5-23.5ZM240-160v-400 400Zm0 80q-33 0-56.5-23.5T160-160v-400q0-33 23.5-56.5T240-640h280v-80q0-83 58.5-141.5T720-920q83 0 141.5 58.5T920-720h-80q0-50-35-85t-85-35q-50 0-85 35t-35 85v80h120q33 0 56.5 23.5T800-560v400q0 33-23.5 56.5T720-80H240Z"/></svg>';

const String _lockOpenRightFilled =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960"><path d="M536.5-303.5Q560-327 560-360t-23.5-56.5Q513-440 480-440t-56.5 23.5Q400-393 400-360t23.5 56.5Q447-280 480-280t56.5-23.5ZM240-80q-33 0-56.5-23.5T160-160v-400q0-33 23.5-56.5T240-640h280v-80q0-83 58.5-141.5T720-920q83 0 141.5 58.5T920-720h-80q0-50-35-85t-85-35q-50 0-85 35t-35 85v80h120q33 0 56.5 23.5T800-560v400q0 33-23.5 56.5T720-80H240Z"/></svg>';
