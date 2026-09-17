import 'package:flutter/material.dart';

import '../format.dart';

class Sparkline extends StatefulWidget {
  const Sparkline({
    super.key,
    required this.values,
    required this.color,
    this.times,
    this.window = const Duration(seconds: 60),
    this.height = 108,
  });

  final List<int> values;
  final List<DateTime>? times;
  final Color color;
  final Duration window;
  final double height;

  @override
  State<Sparkline> createState() => _SparklineState();
}

class _Point {
  const _Point(this.at, this.value);

  final DateTime at;
  final int value;
}

class _SparklineState extends State<Sparkline> {
  int? _hover;

  List<_Point> _points(DateTime now) {
    final DateTime start = now.subtract(widget.window);
    final List<int> values = widget.values;
    final List<DateTime>? times = widget.times;
    if (times != null && times.length == values.length) {
      return <_Point>[
        for (int i = 0; i < values.length; i++)
          if (!times[i].isBefore(start)) _Point(times[i], values[i]),
      ];
    }
    if (values.length < 2) {
      return <_Point>[
        for (final int value in values) _Point(now, value),
      ];
    }
    return <_Point>[
      for (int i = 0; i < values.length; i++)
        _Point(
          now.subtract(
            widget.window * ((values.length - 1 - i) / (values.length - 1)),
          ),
          values[i],
        ),
    ];
  }

  void _inspect(Offset local, Size size, DateTime now, List<_Point> points) {
    if (points.isEmpty) {
      if (_hover != null) {
        setState(() => _hover = null);
      }
      return;
    }
    final _ChartMetrics metrics = _ChartMetrics.measure(
      size: size,
      points: points,
      now: now,
      window: widget.window,
      labelStyle: _labelStyle(Theme.of(context)),
    );
    if (!metrics.plot.inflate(6).contains(local)) {
      if (_hover != null) {
        setState(() => _hover = null);
      }
      return;
    }
    final DateTime start = now.subtract(widget.window);
    final double t = ((local.dx - metrics.plot.left) / metrics.plot.width)
        .clamp(0.0, 1.0);
    final DateTime target = start.add(
      Duration(milliseconds: (widget.window.inMilliseconds * t).round()),
    );
    int best = 0;
    int bestDelta = 1 << 30;
    for (int i = 0; i < points.length; i++) {
      final int delta = points[i].at.difference(target).inMilliseconds.abs();
      if (delta < bestDelta) {
        best = i;
        bestDelta = delta;
      }
    }
    if (_hover != best) {
      setState(() => _hover = best);
    }
  }

  TextStyle _labelStyle(ThemeData theme) =>
      (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
        fontSize: 10,
        height: 1,
        color: theme.colorScheme.onSurfaceVariant,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final DateTime now = DateTime.now();
    final List<_Point> points = _points(now);
    final int? hover = _hover != null && _hover! < points.length
        ? _hover
        : null;
    final TextStyle labels = _labelStyle(theme);

    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size size = Size(constraints.maxWidth, widget.height);
          final _ChartMetrics metrics = _ChartMetrics.measure(
            size: size,
            points: points,
            now: now,
            window: widget.window,
            labelStyle: labels,
          );
          final _Point? active = hover == null ? null : points[hover];

          return MouseRegion(
            onHover: (PointerEvent event) =>
                _inspect(event.localPosition, size, now, points),
            onExit: (_) {
              if (_hover != null) {
                setState(() => _hover = null);
              }
            },
            child: Listener(
              onPointerDown: (PointerDownEvent event) =>
                  _inspect(event.localPosition, size, now, points),
              onPointerMove: (PointerMoveEvent event) =>
                  _inspect(event.localPosition, size, now, points),
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  CustomPaint(
                    size: size,
                    painter: _SparklinePainter(
                      points: points,
                      metrics: metrics,
                      color: widget.color,
                      axisColor: scheme.outlineVariant,
                      labelStyle: labels,
                      hover: hover,
                    ),
                  ),
                  if (active != null)
                    _Tip(
                      metrics: metrics,
                      point: active,
                      scheme: scheme,
                      style: theme.tooltipTheme.textStyle,
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip({
    required this.metrics,
    required this.point,
    required this.scheme,
    required this.style,
  });

  final _ChartMetrics metrics;
  final _Point point;
  final ColorScheme scheme;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final Offset pos = metrics.offsetOf(point);
    const double width = 108;
    final double left = (pos.dx - width / 2).clamp(
      0.0,
      metrics.size.width - width,
    );
    final double top = (pos.dy - 38).clamp(0.0, metrics.plot.top);

    return Positioned(
      left: left,
      top: top,
      width: width,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.inverseSurface,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            child: Text(
              '${Format.clock(point.at)}\n${Format.speed(point.value)}',
              textAlign: TextAlign.center,
              style:
                  style ??
                  TextStyle(fontSize: 12, color: scheme.onInverseSurface),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChartMetrics {
  const _ChartMetrics({
    required this.size,
    required this.plot,
    required this.peak,
    required this.start,
    required this.now,
    required this.window,
    required this.yWidth,
  });

  final Size size;
  final Rect plot;
  final int peak;
  final DateTime start;
  final DateTime now;
  final Duration window;
  final double yWidth;

  static _ChartMetrics measure({
    required Size size,
    required List<_Point> points,
    required DateTime now,
    required Duration window,
    required TextStyle labelStyle,
  }) {
    final int peak = points.fold<int>(0, (int a, _Point b) {
      return a > b.value ? a : b.value;
    });
    final DateTime start = now.subtract(window);
    double yWidth = 0;
    for (final int value in <int>[peak, peak ~/ 2, 0]) {
      final TextPainter painter = TextPainter(
        text: TextSpan(text: Format.speed(value), style: labelStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      if (painter.width > yWidth) {
        yWidth = painter.width;
      }
    }
    const double bottom = 16;
    const double top = 10;
    const double right = 4;
    return _ChartMetrics(
      size: size,
      plot: Rect.fromLTWH(
        yWidth + 6,
        top,
        (size.width - yWidth - 6 - right).clamp(1, size.width),
        (size.height - top - bottom).clamp(1, size.height),
      ),
      peak: peak,
      start: start,
      now: now,
      window: window,
      yWidth: yWidth,
    );
  }

  Offset offsetOf(_Point point) {
    final double t =
        point.at.difference(start).inMilliseconds / window.inMilliseconds;
    final double x = plot.left + plot.width * t.clamp(0.0, 1.0);
    final double y = peak <= 0
        ? plot.bottom
        : plot.bottom - (point.value / peak) * plot.height;
    return Offset(x, y);
  }
}

class _SparklinePainter extends CustomPainter {
  const _SparklinePainter({
    required this.points,
    required this.metrics,
    required this.color,
    required this.axisColor,
    required this.labelStyle,
    required this.hover,
  });

  final List<_Point> points;
  final _ChartMetrics metrics;
  final Color color;
  final Color axisColor;
  final TextStyle labelStyle;
  final int? hover;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect plot = metrics.plot;
    final Paint grid = Paint()
      ..color = axisColor.withValues(alpha: 0.55)
      ..strokeWidth = 1;

    for (final double t in <double>[0, 0.5, 1]) {
      final double y = plot.bottom - plot.height * t;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
    }
    canvas.drawLine(
      plot.bottomLeft,
      plot.bottomRight,
      Paint()
        ..color = axisColor
        ..strokeWidth = 1,
    );
    canvas.drawLine(
      plot.bottomLeft,
      plot.topLeft,
      Paint()
        ..color = axisColor
        ..strokeWidth = 1,
    );

    _label(
      canvas,
      Format.speed(metrics.peak),
      Offset(plot.left - 5, plot.top),
      align: Alignment.centerRight,
      yCenter: true,
    );
    _label(
      canvas,
      Format.speed(metrics.peak ~/ 2),
      Offset(plot.left - 5, plot.center.dy),
      align: Alignment.centerRight,
      yCenter: true,
    );
    _label(
      canvas,
      Format.speed(0),
      Offset(plot.left - 5, plot.bottom),
      align: Alignment.centerRight,
      yCenter: true,
    );

    final DateTime mid = metrics.start.add(
      Duration(milliseconds: metrics.window.inMilliseconds ~/ 2),
    );
    _label(
      canvas,
      Format.clock(metrics.start),
      Offset(plot.left, plot.bottom + 4),
    );
    _label(
      canvas,
      Format.clock(mid),
      Offset(plot.center.dx, plot.bottom + 4),
      align: Alignment.topCenter,
    );
    _label(
      canvas,
      Format.clock(metrics.now),
      Offset(plot.right, plot.bottom + 4),
      align: Alignment.topRight,
    );

    final Path line = Path();
    if (points.isEmpty) {
      line
        ..moveTo(plot.left, plot.bottom)
        ..lineTo(plot.right, plot.bottom);
    } else {
      for (int i = 0; i < points.length; i++) {
        final Offset p = metrics.offsetOf(points[i]);
        i == 0 ? line.moveTo(p.dx, p.dy) : line.lineTo(p.dx, p.dy);
      }
    }

    if (points.isNotEmpty) {
      final Offset first = metrics.offsetOf(points.first);
      final Offset last = metrics.offsetOf(points.last);
      final Path fill = Path.from(line)
        ..lineTo(last.dx, plot.bottom)
        ..lineTo(first.dx, plot.bottom)
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
          ).createShader(plot),
      );
    }

    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    final int? hover = this.hover;
    if (hover != null && hover < points.length) {
      final Offset p = metrics.offsetOf(points[hover]);
      canvas.drawLine(
        Offset(p.dx, plot.top),
        Offset(p.dx, plot.bottom),
        Paint()
          ..color = color.withValues(alpha: 0.7)
          ..strokeWidth = 1,
      );
      canvas.drawCircle(p, 3.2, Paint()..color = color);
    }
  }

  void _label(
    Canvas canvas,
    String text,
    Offset anchor, {
    Alignment align = Alignment.topLeft,
    bool yCenter = false,
  }) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: labelStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    double dx = anchor.dx;
    double dy = anchor.dy;
    if (align == Alignment.centerRight || align == Alignment.topRight) {
      dx -= painter.width;
    } else if (align == Alignment.topCenter) {
      dx -= painter.width / 2;
    }
    if (yCenter) {
      dy -= painter.height / 2;
    }
    painter.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.color != color ||
      old.axisColor != axisColor ||
      old.hover != hover ||
      old.metrics.peak != metrics.peak ||
      old.metrics.now != metrics.now ||
      !_same(old.points, points);

  static bool _same(List<_Point> a, List<_Point> b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i].value != b[i].value || a[i].at != b[i].at) {
        return false;
      }
    }
    return true;
  }
}
