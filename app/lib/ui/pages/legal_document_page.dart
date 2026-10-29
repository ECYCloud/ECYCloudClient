import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/overlay_scroll_view.dart';
import '../widgets/rich_html_view.dart';

class LegalDocumentPage extends StatefulWidget {
  const LegalDocumentPage({
    super.key,
    required this.title,
    required this.emptyMessage,
    required this.loadContent,
  });

  final String title;
  final String emptyMessage;
  final Future<String> Function() loadContent;

  @override
  State<LegalDocumentPage> createState() => _LegalDocumentPageState();
}

class _LegalDocumentPageState extends State<LegalDocumentPage> {
  final ScrollController _scroll = ScrollController();
  Future<String>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= widget.loadContent();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return AppScaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: FutureBuilder<String>(
        future: _future,
        builder: (BuildContext context, AsyncSnapshot<String> snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '${snap.error}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => setState(() {
                        _future = widget.loadContent();
                      }),
                      child: Text(L10n.t('重试')),
                    ),
                  ],
                ),
              ),
            );
          }
          final String html = snap.data ?? '';
          if (html.trim().isEmpty) {
            return Center(
              child: Text(
                widget.emptyMessage,
                style: theme.textTheme.bodyLarge,
              ),
            );
          }
          return OverlayScrollView(
            controller: _scroll,
            padding: const EdgeInsets.all(AppTheme.overlayScrollGutter),
            child: RichHtmlView(html),
          );
        },
      ),
    );
  }
}
