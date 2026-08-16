import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';

class SimpleDataTable extends StatelessWidget {
  const SimpleDataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.emptyText,
    this.minWidth,
    this.framed = true,
  });

  final List<String> columns;
  final List<List<Widget>> rows;
  final String? emptyText;
  final double? minWidth;
  final bool framed;

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
        final Widget body = available < contentMin
            ? _MobileList(
                columns: columns,
                rows: rows,
                emptyText: empty,
              )
            : _WideTable(
                columns: columns,
                rows: rows,
                emptyText: empty,
                availableWidth: available,
                minWidth: contentMin,
                framed: framed,
              );

        if (!framed) {
          return body;
        }

        return Card(clipBehavior: Clip.antiAlias, child: body);
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
    required this.framed,
  });

  final List<String> columns;
  final List<List<Widget>> rows;
  final String emptyText;
  final double availableWidth;
  final double? minWidth;
  final bool framed;

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
    final double tableWidth =
        availableWidth > contentMin ? availableWidth : contentMin;

    if (rows.isEmpty) {
      return SizedBox(
        width: availableWidth,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: Center(
            child: Text(
              emptyText,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    final Map<int, TableColumnWidth> widths = <int, TableColumnWidth>{
      for (int i = 0; i < columns.length; i++) i: const FlexColumnWidth(),
    };

    final Widget table = Table(
      columnWidths: widths,
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder(
        horizontalInside: BorderSide(
          color: scheme.outlineVariant,
          width: 0.5,
        ),
      ),
      children: <TableRow>[
        TableRow(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
          ),
          children: <Widget>[
            for (final String title in columns)
              _Cell(
                padding: EdgeInsets.fromLTRB(
                  framed ? 16 : 0,
                  12,
                  framed ? 16 : 0,
                  12,
                ),
                child: Text(title, style: headerStyle),
              ),
          ],
        ),
        for (final List<Widget> cells in rows)
          TableRow(
            children: <Widget>[
              for (int i = 0; i < columns.length; i++)
                _Cell(
                  padding: EdgeInsets.fromLTRB(
                    framed ? 16 : 0,
                    12,
                    framed ? 16 : 0,
                    12,
                  ),
                  child: i < cells.length ? cells[i] : const SizedBox.shrink(),
                ),
            ],
          ),
      ],
    );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: tableWidth,
          maxWidth: tableWidth,
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
    this.maxLines = 3,
  });

  final String text;
  final bool muted;
  final bool bold;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Text(
      text.isEmpty ? '—' : text,
      maxLines: maxLines,
      softWrap: true,
      overflow: TextOverflow.ellipsis,
      style: (bold ? theme.textTheme.bodyMedium : theme.textTheme.bodySmall)
          ?.copyWith(
            fontWeight: bold ? FontWeight.w600 : null,
            color: muted ? theme.colorScheme.onSurfaceVariant : null,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
    );
  }
}

class TableMoney extends StatelessWidget {
  const TableMoney(this.amount, {super.key});

  final double amount;

  @override
  Widget build(BuildContext context) => TableText(
    '¥ ${amount.toStringAsFixed(2)}',
    bold: true,
  );
}
