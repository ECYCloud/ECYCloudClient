import 'package:flutter/material.dart';

class UpdateProgressBar extends StatelessWidget {
  const UpdateProgressBar({
    super.key,
    required this.percent,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 10),
  });

  final int? percent;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: LinearProgressIndicator(
      value: percent == null ? null : percent! / 100,
      minHeight: 3,
      borderRadius: BorderRadius.circular(999),
    ),
  );
}
