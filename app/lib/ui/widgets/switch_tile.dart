import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme.dart';

// Switch 轨道尺寸 Material 写死，SwitchListTile 不能换内部开关
class SwitchTile extends StatelessWidget {
  const SwitchTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.icon,
    this.contentPadding,
    this.onSettings,
    this.settingsTooltip,
    this.toggleOnTap = false,
    this.mouseCursor,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final IconData? icon;
  final EdgeInsetsGeometry? contentPadding;
  final VoidCallback? onSettings;
  final String? settingsTooltip;
  final bool toggleOnTap;
  final MouseCursor? mouseCursor;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return ListTile(
      contentPadding: contentPadding,
      mouseCursor: mouseCursor,
      onTap: toggleOnTap && onChanged != null ? () => onChanged!(!value) : null,
      leading: icon == null
          ? null
          : Icon(
              icon,
              size: 18,
              color: value ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
      minLeadingWidth: 18,
      horizontalTitleGap: 10,
      title: onSettings == null
          ? Text(title)
          : _SettingsTitle(
              title: title,
              button: IconButton(
                tooltip: settingsTooltip,
                icon: Icon(
                  Icons.settings_outlined,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                visualDensity: VisualDensity.standard,
                constraints: AppTheme.iconButtonBox,
                padding: EdgeInsets.zero,
                onPressed: onSettings,
              ),
            ),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Transform.scale(
        scale: AppTheme.switchScale,
        alignment: Alignment.centerRight,
        child: Switch(
          value: value,
          onChanged: onChanged,
          mouseCursor: mouseCursor,
          splashRadius: 0,
        ),
      ),
    );
  }
}

// 图标对准标题实际笔画的上下中线。行框中线和按字号估的中线都随设备字体（含系统中文
// 回退字体）的上下伸与字形位置而偏，只能把标题画一遍量出笔画范围。
class _SettingsTitle extends StatefulWidget {
  const _SettingsTitle({required this.title, required this.button});

  final String title;
  final Widget button;

  @override
  State<_SettingsTitle> createState() => _SettingsTitleState();
}

class _SettingsTitleState extends State<_SettingsTitle> {
  static final Map<String, double> _inkCenters = <String, double>{};

  late TextPainter _painter;
  String _key = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _layout();
  }

  @override
  void didUpdateWidget(_SettingsTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title) {
      _layout();
    }
  }

  @override
  void dispose() {
    _painter.dispose();
    super.dispose();
  }

  void _layout() {
    final TextStyle style = DefaultTextStyle.of(
      context,
    ).style.copyWith(color: const Color(0xFF000000));
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final double ratio = MediaQuery.devicePixelRatioOf(context);
    if (_key.isNotEmpty) {
      _painter.dispose();
    }
    _painter = TextPainter(
      text: TextSpan(text: widget.title, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    _key = '${widget.title}|$style|$scaler|$ratio';
    if (!_inkCenters.containsKey(_key)) {
      unawaited(_measure(_key, ratio));
    }
  }

  Future<void> _measure(String key, double ratio) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    _painter.paint(Canvas(recorder)..scale(ratio), Offset.zero);
    final ui.Picture picture = recorder.endRecording();
    final int width = math.max(1, (_painter.width * ratio).ceil());
    final int height = math.max(1, (_painter.height * ratio).ceil());
    final ui.Image image = picture.toImageSync(width, height);
    picture.dispose();
    final ByteData? pixels = await image.toByteData();
    image.dispose();
    if (pixels == null) {
      return;
    }
    int top = -1;
    int bottom = -1;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        if (pixels.getUint8((y * width + x) * 4 + 3) > 0) {
          if (top < 0) {
            top = y;
          }
          bottom = y;
          break;
        }
      }
    }
    if (top < 0) {
      return;
    }
    _inkCenters[key] = (top + bottom + 1) / 2 / ratio;
    if (mounted && key == _key) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final double center = _inkCenters[_key] ?? _painter.height / 2;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Flexible(child: Text(widget.title, overflow: TextOverflow.ellipsis)),
        _GlyphCentered(
          lift:
              _painter.computeDistanceToActualBaseline(
                TextBaseline.alphabetic,
              ) -
              center,
          child: widget.button,
        ),
      ],
    );
  }
}

class _GlyphCentered extends SingleChildRenderObjectWidget {
  const _GlyphCentered({required this.lift, super.child});

  final double lift;

  @override
  _RenderGlyphCentered createRenderObject(BuildContext context) =>
      _RenderGlyphCentered(lift);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderGlyphCentered renderObject,
  ) {
    renderObject.lift = lift;
  }
}

class _RenderGlyphCentered extends RenderProxyBox {
  _RenderGlyphCentered(this._lift);

  double _lift;

  set lift(double value) {
    if (value == _lift) {
      return;
    }
    _lift = value;
    markNeedsLayout();
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      size.height / 2 + _lift;

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => getDryLayout(constraints).height / 2 + _lift;
}
