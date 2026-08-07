import 'package:flutter/material.dart';

/// 与侧栏连接状态图标垂直居中对齐。
///
/// NavigationRail 默认上下各约 8px 内边距，其 leading 里的状态图标为 32×32；
/// 标题放在等高盒子内居中，右侧操作区可更高，整行按中线对齐。
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.actions});

  final String title;
  final List<Widget>? actions;

  static const double _railPaddingTop = 8;
  static const double _brandSize = 32;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(14, _railPaddingTop, 10, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              SizedBox(
                height: _brandSize,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              const Spacer(),
              ...?actions,
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}
