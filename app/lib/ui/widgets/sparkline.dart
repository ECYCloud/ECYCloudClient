import 'package:flutter/material.dart';

/// 速率走势图：折线 + 填充。纵向按窗口内最大值自适应，
/// 全零时画一条贴底的直线，而不是把噪声放大成锯齿。
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    required this.color,
    this.capacity = 60,
    this.height = 46,
  });

  final List<int> values;
  final Color color;

  /// 采样点不足时右对齐留白，图形不会随点数增加而横向拉伸
  final int capacity;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    width: double.infinity,
    child: CustomPaint(
      painter: _SparklinePainter(
        values: values,
        color: color,
        capacity: capacity,
      ),
    ),
  );
}

class _SparklinePainter extends CustomPainter {
  const _SparklinePainter({
    required this.values,
    required this.color,
    required this.capacity,
  });

  final List<int> values;
  final Color color;
  final int capacity;

  @override
  void paint(Canvas canvas, Size size) {
    final int slots = capacity < 2 ? 2 : capacity;
    final double step = size.width / (slots - 1);
    final int peak = values.fold<int>(0, (int a, int b) => a > b ? a : b);
    final double scale = peak <= 0 ? 0 : (size.height - 2) / peak;

    final Path line = Path();
    final int offset = slots - values.length;

    for (int i = 0; i < values.length; i++) {
      final double x = (offset + i) * step;
      final double y = size.height - 1 - values[i] * scale;
      i == 0 ? line.moveTo(x, y) : line.lineTo(x, y);
    }

    if (values.isEmpty) {
      line
        ..moveTo(0, size.height - 1)
        ..lineTo(size.width, size.height - 1);
    } else if (offset > 0) {
      // 左侧没有数据的区间贴底补平，视觉上是「还没开始」而不是从零飙升
      final Path head = Path()
        ..moveTo(0, size.height - 1)
        ..lineTo(offset * step, size.height - 1);
      canvas.drawPath(
        head,
        Paint()
          ..color = color.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    final Path fill = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(offset * step, size.height)
      ..close();

    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            color.withValues(alpha: 0.28),
            color.withValues(alpha: 0.02),
          ],
        ).createShader(Offset.zero & size),
    );

    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.color != color ||
      old.capacity != capacity ||
      !_sameValues(old.values, values);

  static bool _sameValues(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}
