import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import 'overlay_scroll_view.dart';

class SimpleDataTable extends StatelessWidget {
  const SimpleDataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.emptyText,
    this.minWidth,
    this.columnWidths,
    this.framed = true,
    this.stickyHeader = false,
  });

  final List<String> columns;
  final List<List<Widget>> rows;
  final String? emptyText;
  final double? minWidth;
  final Map<int, TableColumnWidth>? columnWidths;
  final bool framed;
  final bool stickyHeader;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final String empty = emptyText ?? L10n.t('暂无数据');
        final double available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final double contentMin =
            minWidth ?? (columns.length * 140.0).clamp(360.0, 1600.0);
        final bool pinHeader = stickyHeader && constraints.maxHeight.isFinite;
        final Widget list = _MobileList(
          columns: columns,
          rows: rows,
          emptyText: empty,
        );
        final Widget body = available < contentMin
            ? pinHeader
                  ? OverlayScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: list,
                    )
                  : list
            : _WideTable(
                columns: columns,
                rows: rows,
                emptyText: empty,
                availableWidth: available,
                minWidth: contentMin,
                columnWidths: columnWidths,
                framed: framed,
                pinHeader: pinHeader,
                viewportHeight: pinHeader ? constraints.maxHeight : null,
              );

        Widget boxed = body;
        if (framed) {
          boxed = Card(clipBehavior: Clip.antiAlias, child: boxed);
        }
        if (pinHeader) {
          boxed = SizedBox(height: constraints.maxHeight, child: boxed);
        }
        return boxed;
      },
    );
  }
}

class _WideTable extends StatelessWidget {
  const _WideTable({
    required this.columns,
    required this.rows,
    required this.emptyText,
    required this.availableWidth,
    required this.minWidth,
    required this.columnWidths,
    required this.framed,
    required this.pinHeader,
    required this.viewportHeight,
  });

  final List<String> columns;
  final List<List<Widget>> rows;
  final String emptyText;
  final double availableWidth;
  final double? minWidth;
  final Map<int, TableColumnWidth>? columnWidths;
  final bool framed;
  final bool pinHeader;
  final double? viewportHeight;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle headerStyle = theme.textTheme.labelMedium!.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    final double contentMin =
        minWidth ?? (columns.length * 140.0).clamp(360.0, 1600.0);
    final double tableWidth = availableWidth > contentMin
        ? availableWidth
        : contentMin;

    if (rows.isEmpty) {
      final Widget empty = Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Text(
            emptyText,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
      return SizedBox(
        width: availableWidth,
        child: pinHeader
            ? OverlayScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: empty,
              )
            : empty,
      );
    }

    final Map<int, TableColumnWidth> widths = <int, TableColumnWidth>{
      for (int i = 0; i < columns.length; i++)
        i: pinHeader && columnWidths?[i] is IntrinsicColumnWidth
            ? const FlexColumnWidth()
            : columnWidths?[i] ?? const FlexColumnWidth(),
    };
    final Color headerColor = pinHeader
        ? Color.alphaBlend(
            scheme.surfaceContainerHighest.withValues(alpha: 0.45),
            scheme.surface,
          )
        : scheme.surfaceContainerHighest.withValues(alpha: 0.45);
    final EdgeInsets cellPadding = EdgeInsets.fromLTRB(
      framed ? 16 : 0,
      12,
      framed ? 16 : 0,
      12,
    );

    TableRow headerRow() {
      return TableRow(
        decoration: BoxDecoration(color: headerColor),
        children: <Widget>[
          for (final String title in columns)
            _Cell(
              padding: cellPadding,
              child: Text(title, style: headerStyle),
            ),
        ],
      );
    }

    List<TableRow> bodyRows() {
      return <TableRow>[
        for (final List<Widget> cells in rows)
          TableRow(
            children: <Widget>[
              for (int i = 0; i < columns.length; i++)
                _Cell(
                  padding: cellPadding,
                  child: i < cells.length ? cells[i] : const SizedBox.shrink(),
                ),
            ],
          ),
      ];
    }

    Table tableOf(List<TableRow> children) {
      return Table(
        columnWidths: widths,
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        border: TableBorder(
          horizontalInside: BorderSide(
            color: scheme.outlineVariant,
            width: 0.5,
          ),
        ),
        children: children,
      );
    }

    final Widget table = pinHeader
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              tableOf(<TableRow>[headerRow()]),
              Expanded(
                child: OverlayScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: tableOf(bodyRows()),
                ),
              ),
            ],
          )
        : tableOf(<TableRow>[headerRow(), ...bodyRows()]);

    return OverlayScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: tableWidth,
          maxWidth: tableWidth,
          maxHeight: viewportHeight ?? double.infinity,
        ),
        child: table,
      ),
    );
  }
}

class _MobileList extends StatelessWidget {
  const _MobileList({
    required this.columns,
    required this.rows,
    required this.emptyText,
  });

  final List<String> columns;
  final List<List<Widget>> rows;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Text(
            emptyText,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Column(
      children: <Widget>[
        for (int r = 0; r < rows.length; r++) ...<Widget>[
          if (r > 0) Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (int c = 0; c < columns.length; c++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(
                          width: 96,
                          child: Text(
                            columns[c],
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: c < rows[r].length
                              ? rows[r][c]
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.child, required this.padding});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(padding: padding, child: child);
}

class TableText extends StatelessWidget {
  const TableText(
    this.text, {
    super.key,
    this.muted = false,
    this.bold = false,
    this.color,
  });

  final String text;
  final bool muted;
  final bool bold;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Text(
      text.isEmpty ? '—' : text,
      softWrap: true,
      style: (bold ? theme.textTheme.bodyMedium : theme.textTheme.bodySmall)
          ?.copyWith(
            fontWeight: bold ? FontWeight.w600 : null,
            color: color ?? (muted ? theme.colorScheme.onSurfaceVariant : null),
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
    );
  }
}

class TableMoney extends StatelessWidget {
  const TableMoney(this.amount, {super.key});

  final double amount;

  @override
  Widget build(BuildContext context) =>
      TableText('¥ ${amount.toStringAsFixed(2)}', bold: true);
}
