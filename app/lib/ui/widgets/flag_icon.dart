import 'package:flutter/material.dart';

import 'icon_image.dart';

/// 节点地区旗帜，取 `assets/flags/<iso>.svg`，与面板 `/images/flags` 同一套素材。
/// 该地区没有旗帜素材时退回字母角标。
class FlagIcon extends StatelessWidget {
  const FlagIcon({super.key, required this.code, this.width = 18});

  final String code;
  final double width;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(2),
    child: LocalIcon(
      assets: <String>['assets/flags/$code.svg'],
      width: width,
      height: width * 0.75,
      fit: BoxFit.cover,
      fallback: _LetterBadge(code: code),
    ),
  );
}

class _LetterBadge extends StatelessWidget {
  const _LetterBadge({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest),
      child: Center(
        child: Text(
          code.toUpperCase(),
          style: TextStyle(
            fontSize: 8,
            height: 1,
            fontWeight: FontWeight.w700,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
