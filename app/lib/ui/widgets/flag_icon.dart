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
      // xx 是 flag-icons 自带的未知旗占位，与真旗同为 4:3，缺图时行内尺寸不变
      child: LocalIcon(
        assets: <String>['assets/flags/$code.svg', 'assets/flags/xx.svg'],
        width: width,
        height: width * 0.75,
        fit: BoxFit.cover,
      ),
    ),
  );
}
