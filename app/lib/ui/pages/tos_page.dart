import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../app_scope.dart';
import '../widgets/rich_html_view.dart';

class TosPage extends StatefulWidget {
  const TosPage({super.key});

  @override
  State<TosPage> createState() => _TosPageState();
}

class _TosPageState extends State<TosPage> {
  final ScrollController _scroll = ScrollController();
  Future<String>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= AppScope.of(context).auth.fetchTos();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(L10n.t('服务条款'))),
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
                        _future = AppScope.of(context).auth.fetchTos();
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
              child: Text(L10n.t('暂无服务条款'), style: theme.textTheme.bodyLarge),
            );
          }
          return Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              child: RichHtmlView(html),
            ),
          );
        },
      ),
    );
  }
}
