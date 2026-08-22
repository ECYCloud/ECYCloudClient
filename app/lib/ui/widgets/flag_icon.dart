import 'package:flutter/material.dart';

import 'icon_image.dart';

class FlagIcon extends StatelessWidget {
  const FlagIcon({super.key, required this.code, this.width = 18});

  final String code;
  final double width;

  // 雅黑 ascent(2167) 与 descent(536) 不对称，汉字墨迹中线比行盒中线低 0.1~0.4px
  // （随字号取整浮动），旗帜按行盒居中就会偏上。上边距在居中时只生效一半，故取 0.6。
  static const EdgeInsets _inkInset = EdgeInsets.only(top: 0.6);

  @override
  Widget build(BuildContext context) => Padding(
    padding: _inkInset,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LocalIcon(
        assets: <String>['assets/flags/$code.svg'],
        width: width,
        height: width * 0.75,
        fit: BoxFit.cover,
        fallback: _LetterBadge(code: code),
      ),
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
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
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
