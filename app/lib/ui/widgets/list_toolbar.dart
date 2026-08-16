import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'option_dropdown.dart';
import 'search_field.dart';
import '../../l10n/l10n.dart';

/// 列表页搜索 + 每页条数 + 翻页 / 跳页。
///
/// 每页条数复用 [OptionDropdown]，搜索复用 [SearchField]；
/// 控件高度统一为 [rowHeight]，翻页键与刷新按钮同一套触摸尺寸。
class ListToolbar extends StatefulWidget {
  const ListToolbar({
    super.key,
    required this.currentPage,
    required this.lastPage,
    required this.total,
    required this.perPage,
    required this.onSearchChanged,
    required this.onPerPageChanged,
    required this.onPageChanged,
    this.searchHint,
    this.showSearch = true,
  });

  final int currentPage;
  final int lastPage;
  final int total;
  final int perPage;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<int> onPerPageChanged;
  final ValueChanged<int> onPageChanged;
  final String? searchHint;
  final bool showSearch;

  static const List<int> pageSizes = <int>[10, 25, 50, 100];
  static double get rowHeight =>
      AppTheme.touchDevice ? kMinInteractiveDimension : 30;
  static const double _gap = 8;

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
    final int clamped = page.clamp(1, widget.lastPage < 1 ? 1 : widget.lastPage);
    widget.onPageChanged(clamped);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? fieldStyle = theme.textTheme.bodyMedium?.copyWith(
      fontSize: 12,
      height: 1.0,
    );
    final bool canPrev = widget.currentPage > 1;
    final bool canNext = widget.currentPage < widget.lastPage;
    final int perPage = ListToolbar.pageSizes.contains(widget.perPage)
        ? widget.perPage
        : 10;
    final int lastPage = widget.lastPage < 1 ? 1 : widget.lastPage;

    final Widget perPageDropdown = OptionDropdown<int>(
      value: perPage,
      width: 120,
      height: ListToolbar.rowHeight,
      options: <int, String>{
        for (final int size in ListToolbar.pageSizes) size: L10n.t('每页 {0} 项', <Object>[size]),
      },
      onChanged: widget.onPerPageChanged,
    );
    final Widget stats = Text(
      L10n.t('共 {0} 条 · 第 {1}/{2} 页', <Object>[widget.total, widget.currentPage, lastPage]),
      style: theme.textTheme.bodySmall,
    );
    final Widget prevButton = IconButton(
      tooltip: L10n.t('上一页'),
      onPressed: canPrev
          ? () => widget.onPageChanged(widget.currentPage - 1)
          : null,
      icon: const Icon(Icons.chevron_left, size: 20),
      padding: EdgeInsets.zero,
      visualDensity: AppTheme.iconActionDensity,
      constraints: AppTheme.iconActionBox(compact: 24),
    );
    final Widget nextButton = IconButton(
      tooltip: L10n.t('下一页'),
      onPressed: canNext
          ? () => widget.onPageChanged(widget.currentPage + 1)
          : null,
      icon: const Icon(Icons.chevron_right, size: 20),
      padding: EdgeInsets.zero,
      visualDensity: AppTheme.iconActionDensity,
      constraints: AppTheme.iconActionBox(compact: 24),
    );
    final Widget jumpField = SizedBox(
      width: 64,
      height: ListToolbar.rowHeight,
      child: TextField(
        controller: _jump,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        textAlignVertical: TextAlignVertical.center,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
        ],
        style: fieldStyle,
        decoration: InputDecoration(
          hintText: L10n.t('页码'),
          // 与 SearchField 相同：用 30 高 icon 槽把输入行撑满，文字垂直居中
          prefixIcon: SizedBox(height: ListToolbar.rowHeight),
          prefixIconConstraints: BoxConstraints.tightFor(
            width: 10,
            height: ListToolbar.rowHeight,
          ),
          suffixIcon: SizedBox(height: ListToolbar.rowHeight),
          suffixIconConstraints: BoxConstraints.tightFor(
            width: 10,
            height: ListToolbar.rowHeight,
          ),
          contentPadding: EdgeInsets.zero,
        ),
        onSubmitted: (_) => _jumpTo(),
      ),
    );
    final Widget jumpButton = TextButton(
      onPressed: _jumpTo,
      child: Text(L10n.t('跳转')),
    );
    final List<Widget> pageControls = <Widget>[
      stats,
      prevButton,
      nextButton,
      jumpField,
      jumpButton,
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 与 Shell / 日志 / 连接页宽屏断点一致
        final bool narrow = constraints.maxWidth < 640;
        if (narrow) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (widget.showSearch) ...<Widget>[
                  SearchField(
                    hintText: widget.searchHint,
                    width: double.infinity,
                    onChanged: widget.onSearchChanged,
                  ),
                  const SizedBox(height: ListToolbar._gap),
                ],
                Wrap(
                  spacing: ListToolbar._gap,
                  runSpacing: ListToolbar._gap,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    perPageDropdown,
                    ...pageControls,
                  ],
                ),
              ],
            ),
          );
        }

        final List<Widget> items = <Widget>[
          if (widget.showSearch)
            SearchField(
              hintText: widget.searchHint,
              onChanged: widget.onSearchChanged,
            ),
          perPageDropdown,
          ...pageControls,
        ];
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
          child: Align(
            alignment: Alignment.centerRight,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                height: ListToolbar.rowHeight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (int i = 0; i < items.length; i++) ...<Widget>[
                      if (i > 0) const SizedBox(width: ListToolbar._gap),
                      items[i],
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
