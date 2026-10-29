import 'package:flutter/widgets.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

// SliverList 跳到远处须逐个布局中间的条目，拖动滚动条时上千行挤进一帧；这里先按估算定位，
// 再在每帧的布局预算内量完其余条目，总高度与滚动条随之收敛到实际值
class GappedSliverList extends StatelessWidget {
  const GappedSliverList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.gap,
    required this.rowEstimate,
  });

  final int itemCount;
  final NullableIndexedWidgetBuilder itemBuilder;
  final double gap;
  final double rowEstimate;

  static final ExtentPrecalculationPolicy _measureAll = _MeasureAll();

  @override
  Widget build(BuildContext context) => SuperSliverList.separated(
    itemCount: itemCount,
    itemBuilder: itemBuilder,
    separatorBuilder: (_, _) => SizedBox(height: gap),
    addAutomaticKeepAlives: false,
    extentPrecalculationPolicy: _measureAll,
    // 分隔条也是子项，须逐项按实际高度估；index 为 null 时返回正数会被当成所有子项的统一估值
    extentEstimation: (int? index, double _) => index == null
        ? 0
        : index.isOdd
        ? gap
        : rowEstimate,
  );
}

class _MeasureAll extends ExtentPrecalculationPolicy {
  @override
  bool shouldPrecalculateExtents(ExtentPrecalculationContext context) => true;
}
