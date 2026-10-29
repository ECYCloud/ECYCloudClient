import 'dart:async';

import 'package:ecycloud_client/ui/auto_refresh_mixin.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Records extends StatefulWidget {
  const _Records(this.requests, {super.key});

  final List<({String language, Completer<String> result})> requests;

  @override
  State<_Records> createState() => _RecordsState();
}

class _RecordsState extends State<_Records> with AutoRefreshMixin<_Records> {
  bool _started = false;
  bool _busy = false;
  String _value = 'loading';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      startAutoRefresh(() => _load(silent: true));
      unawaited(_load());
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (silent && _busy) return;
    if (!silent) _busy = true;
    await loadLatest(
      () {
        final Completer<String> result = Completer<String>();
        widget.requests.add((
          language: Localizations.localeOf(context).languageCode,
          result: result,
        ));
        return result.future;
      },
      silent: silent,
      onData: (String value) => setState(() {
        _value = value;
        _busy = false;
      }),
      onError: (Object error) => setState(() {
        _value = '$error';
        _busy = false;
      }),
    );
  }

  @override
  Widget build(BuildContext context) => Text(_value);
}

Widget _app(
  String language,
  List<({String language, Completer<String> result})> requests,
) {
  return Localizations(
    locale: Locale(language),
    delegates: const <LocalizationsDelegate<dynamic>>[
      DefaultWidgetsLocalizations.delegate,
    ],
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: _Records(requests, key: const ValueKey<String>('records')),
    ),
  );
}

void main() {
  testWidgets('切换语言立即刷新记录，不重复首次请求', (tester) async {
    final requests = <({String language, Completer<String> result})>[];
    await tester.pumpWidget(_app('zh', requests));
    expect(requests.length, 1);
    requests[0].result.complete('中文记录');
    await tester.pumpAndSettle();
    await tester.pumpWidget(_app('en', requests));
    expect(requests.length, 2);
    expect(requests[1].language, 'en');
    requests[1].result.complete('English records');
    await tester.pumpAndSettle();
    expect(find.text('English records'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final bool fails in <bool>[false, true]) {
    testWidgets('切换语言隔离在途${fails ? '错误' : '数据'}并重取', (tester) async {
      final requests = <({String language, Completer<String> result})>[];
      await tester.pumpWidget(_app('zh', requests));
      await tester.pumpWidget(_app('en', requests));
      if (fails) {
        requests[0].result.completeError(StateError('旧语言错误'));
      } else {
        requests[0].result.complete('旧语言数据');
      }
      await tester.pumpAndSettle();
      expect(find.textContaining('旧语言'), findsNothing);
      expect(requests.last.language, 'en');
      expect(requests.length, 2);
      requests.last.result.complete('English records');
      await tester.pumpAndSettle();
      expect(find.text('English records'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
