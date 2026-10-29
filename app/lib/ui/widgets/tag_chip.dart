import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class TagChip extends StatelessWidget {
  const TagChip({
    super.key,
    required this.label,
    this.color,
    this.icon,
    this.capsule = false,
  });

  static const double capsuleHeight = 20;

  static Widget wrap({
    String protocol = '',
    String network = '',
    String tls = '',
    String udp = '',
  }) => Wrap(
    spacing: 4,
    runSpacing: 4,
    children: <Widget>[
      if (protocol.isNotEmpty) TagChip(label: protocol),
      if (network.isNotEmpty) TagChip(label: network),
      if (tls.isNotEmpty) TagChip(label: tls),
      if (udp.isNotEmpty) TagChip(label: udp),
    ],
  );

  final String label;
  final Color? color;
  final IconData? icon;
  final bool capsule;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color tone = color ?? scheme.onSurfaceVariant;
    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: 11, color: tone),
          SizedBox(width: capsule ? 4 : 3),
        ],
        _TagText(
          label: label,
          capsule: capsule,
          style: Theme.of(context).textTheme.labelSmall!.copyWith(
            fontSize: 10,
            height: capsule ? 1 : 1.4,
            fontWeight: FontWeight.w600,
            color: tone,
            leadingDistribution: capsule ? TextLeadingDistribution.even : null,
          ),
        ),
      ],
    );

    if (capsule) {
      return SizedBox(
        height: capsuleHeight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tone.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: tone.withValues(alpha: 0.3)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Align(
              alignment: Alignment.center,
              widthFactor: 1,
              child: content,
            ),
          ),
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(icon == null ? 6 : 4, 1, 6, 1),
        child: content,
      ),
    );
  }
}

class _TagText extends StatelessWidget {
  const _TagText({
    required this.label,
    required this.style,
    required this.capsule,
  });

  final String label;
  final TextStyle style;
  final bool capsule;

  static final Map<Object, Future<double>> _centers =
      <Object, Future<double>>{};

  static Future<double> _measure(TextPainter painter, double pixelRatio) async {
    final double lineHeight = painter.height;
    final double padding = painter.text!.style!.fontSize!;
    final int width = math.min(
      ((painter.width + padding * 2) * pixelRatio).ceil(),
      2048,
    );
    final int height = math.min(
      ((painter.height + padding * 2) * pixelRatio).ceil(),
      2048,
    );
    final double scaleX = width / (painter.width + padding * 2);
    final double scaleY = height / (painter.height + padding * 2);
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder)..scale(scaleX, scaleY);
    painter.paint(canvas, Offset(padding, padding));
    final ui.Picture picture = recorder.endRecording();
    ui.Image? image;
    try {
      image = await picture.toImage(width, height);
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      int top = height;
      int bottom = -1;
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          if (data.getUint8((y * width + x) * 4 + 3) >= 128) {
            top = math.min(top, y);
            bottom = y;
            break;
          }
        }
      }
      return bottom < 0
          ? lineHeight / 2
          : (top + bottom + 1) / (2 * scaleY) - padding;
    } finally {
      image?.dispose();
      picture.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget text = Text(label, style: style);
    if (capsule) return text;
    final TextStyle measuredStyle = style
        .copyWith(
          color: Colors.white,
          fontWeight: MediaQuery.boldTextOf(context)
              ? FontWeight.bold
              : style.fontWeight,
        )
        .merge(
          TextStyle(
            height: MediaQuery.maybeLineHeightScaleFactorOverrideOf(context),
            letterSpacing: MediaQuery.maybeLetterSpacingOverrideOf(context),
            wordSpacing: MediaQuery.maybeWordSpacingOverrideOf(context),
          ),
        );
    final TextDirection direction = Directionality.of(context);
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final Locale? locale = Localizations.maybeLocaleOf(context);
    final double pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final TextHeightBehavior? behavior =
        DefaultTextStyle.of(context).textHeightBehavior ??
        DefaultTextHeightBehavior.maybeOf(context);
    final TextPainter painter = TextPainter(
      text: TextSpan(text: label, style: measuredStyle),
      textDirection: direction,
      textScaler: scaler,
      locale: locale,
      textHeightBehavior: behavior,
    )..layout();
    final Size size = painter.size;
    final key = (
      label,
      measuredStyle,
      direction,
      scaler,
      locale,
      pixelRatio,
      behavior,
    );
    if (!_centers.containsKey(key)) {
      if (_centers.length >= 128) _centers.remove(_centers.keys.first);
      _centers[key] = _measure(painter, pixelRatio);
    }
    painter.dispose();
    return FutureBuilder<double>(
      key: ValueKey(key),
      future: _centers[key],
      builder: (BuildContext context, AsyncSnapshot<double> snapshot) =>
          CustomSingleChildLayout(
            delegate: _TagTextLayout(size, snapshot.data ?? size.height / 2),
            child: text,
          ),
    );
  }
}

class _TagTextLayout extends SingleChildLayoutDelegate {
  const _TagTextLayout(this.textSize, this.inkCenter);

  final Size textSize;
  final double inkCenter;

  @override
  Size getSize(BoxConstraints constraints) => constraints.constrain(textSize);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.tight(textSize);

  @override
  Offset getPositionForChild(Size size, Size childSize) =>
      Offset(0, size.height / 2 - inkCenter);

  @override
  bool shouldRelayout(_TagTextLayout oldDelegate) =>
      textSize != oldDelegate.textSize || inkCenter != oldDelegate.inkCenter;
}
