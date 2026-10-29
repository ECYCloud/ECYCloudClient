import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'search_field.dart';
import '../../l10n/l10n.dart';
import '../theme.dart';
import 'app_text_field.dart';

class ListToolbar extends StatefulWidget {
  const ListToolbar({
    super.key,
    required this.currentPage,
    required this.lastPage,
    required this.total,
    required this.onSearchChanged,
    required this.onPageChanged,
    this.searchHint,
    this.showSearch = true,
  });

  final int currentPage;
  final int lastPage;
  final int total;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<int> onPageChanged;
  final String? searchHint;
  final bool showSearch;

  static const int pageSize = 10;
  static const double _gap = 4;

  Widget buildSearch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 0, 12),
      child: SearchField(
        hintText: searchHint,
        width: double.infinity,
        onChanged: onSearchChanged,
      ),
    );
  }

  @override
  State<ListToolbar> createState() => _ListToolbarState();
}

class _ListToolbarState extends State<ListToolbar> {
  final TextEditingController _jump = TextEditingController();

  @override
  void dispose() {
    _jump.dispose();
    super.dispose();
  }

  void _jumpTo() {
    final int? page = int.tryParse(_jump.text.trim());
    if (page == null) {
      return;
    }
    final int clamped = page.clamp(
      1,
      widget.lastPage < 1 ? 1 : widget.lastPage,
    );
    widget.onPageChanged(clamped);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double rowHeight = AppTheme.minTapTarget;
    final TextStyle? fieldStyle = theme.textTheme.bodyMedium?.copyWith(
      fontSize: 12,
      height: 1.0,
    );
    final bool canPrev = widget.currentPage > 1;
    final bool canNext = widget.currentPage < widget.lastPage;
    final int lastPage = widget.lastPage < 1 ? 1 : widget.lastPage;
    final List<int> pages = lastPage <= 7
        ? List<int>.generate(lastPage, (int index) => index + 1)
        : (<int>{
              1,
              widget.currentPage - 1,
              widget.currentPage,
              widget.currentPage + 1,
              lastPage,
            }.where((int page) => page >= 1 && page <= lastPage).toList()
            ..sort());
    final ButtonStyle buttonStyle =
        OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          backgroundColor: scheme.surfaceContainerLowest,
          disabledForegroundColor: scheme.onSurfaceVariant.withValues(
            alpha: 0.4,
          ),
          shape: AppTheme.pillShape,
          minimumSize: Size(48, rowHeight),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          visualDensity: AppTheme.controlDensity,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: fieldStyle?.copyWith(fontWeight: FontWeight.w600),
        ).copyWith(
          side: WidgetStateProperty.resolveWith<BorderSide>(
            (Set<WidgetState> states) => BorderSide(
              color: states.contains(WidgetState.disabled)
                  ? scheme.outline.withValues(alpha: scheme.outline.a * 0.4)
                  : scheme.outline,
            ),
          ),
        );

    final Widget stats = Text(
      L10n.t('共 {0} 条 · 第 {1}/{2} 页', <Object>[
        widget.total,
        widget.currentPage,
        lastPage,
      ]),
      style: theme.textTheme.bodySmall,
    );
    final Widget prevButton = OutlinedButton(
      style: buttonStyle,
      onPressed: canPrev
          ? () => widget.onPageChanged(widget.currentPage - 1)
          : null,
      child: Text(L10n.t('上页')),
    );
    final Widget nextButton = OutlinedButton(
      style: buttonStyle,
      onPressed: canNext
          ? () => widget.onPageChanged(widget.currentPage + 1)
          : null,
      child: Text(L10n.t('下页')),
    );
    final Widget jumpField = SizedBox(
      width: 80,
      height: rowHeight,
      child: AppTheme.withControlDensity(
        AppTextField(
          controller: _jump,
          keyboardType: TextInputType.number,
          textAlignVertical: TextAlignVertical.center,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          style: fieldStyle,
          decoration: InputDecoration(
            hintText: L10n.t('跳页'),
            hintStyle: fieldStyle?.copyWith(color: scheme.onSurfaceVariant),
            fillColor: scheme.surfaceContainerLowest,
            constraints: BoxConstraints.tightFor(height: rowHeight),
            prefixIcon: SizedBox(height: rowHeight),
            prefixIconConstraints: BoxConstraints.tightFor(
              width: 10,
              height: rowHeight,
            ),
            suffixIcon: SizedBox(height: rowHeight),
            suffixIconConstraints: BoxConstraints.tightFor(
              width: 10,
              height: rowHeight,
            ),
            contentPadding: EdgeInsets.zero,
          ),
          onSubmitted: (_) => _jumpTo(),
        ),
      ),
    );
    final Widget jumpButton = OutlinedButton(
      style: buttonStyle,
      onPressed: _jumpTo,
      child: Text(L10n.t('确定')),
    );
    final List<Widget> pageControls = <Widget>[
      prevButton,
      for (int index = 0; index < pages.length; index++) ...<Widget>[
        if (index > 0 && pages[index] - pages[index - 1] > 1)
          SizedBox(
            width: rowHeight,
            height: rowHeight,
            child: const Center(child: Text('…')),
          ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            shape: AppTheme.pillShape,
            fixedSize: Size.fromHeight(rowHeight),
            minimumSize: Size.square(rowHeight),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            backgroundColor: pages[index] == widget.currentPage
                ? scheme.onSurface
                : scheme.surfaceContainerLowest,
            foregroundColor: pages[index] == widget.currentPage
                ? scheme.surface
                : scheme.onSurface,
            side: BorderSide(
              color: pages[index] == widget.currentPage
                  ? scheme.onSurface
                  : scheme.outline,
            ),
          ).merge(buttonStyle),
          onPressed: () {
            if (pages[index] != widget.currentPage) {
              widget.onPageChanged(pages[index]);
            }
          },
          child: Text('${pages[index]}', softWrap: false),
        ),
      ],
      nextButton,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.showSearch) widget.buildSearch(),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 0, 4),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 14,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              stats,
              Wrap(
                alignment: WrapAlignment.end,
                spacing: ListToolbar._gap,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: pageControls,
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  jumpField,
                  const SizedBox(width: 6),
                  jumpButton,
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
