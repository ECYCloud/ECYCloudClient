import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ecycloud_client/core/app_config.dart';
import 'package:ecycloud_client/domain/kernel/kernel_update.dart';
import 'package:ecycloud_client/domain/update/app_update.dart';
import 'package:ecycloud_client/domain/update/github_release.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

AppUpdate at(String current, String latest) =>
    AppUpdate(current: current, latest: latest, installer: null);

void main() {
  for (final bool kernel in <bool>[false, true]) {
    testWidgets('${kernel ? '内核' : '软件'}更新在两次 TLS 握手中断后恢复', (tester) async {
      int attempts = 0;
      final client = MockClient((request) async {
        attempts++;
        if (attempts <= 2) {
          throw const HandshakeException(
            'Connection terminated during handshake',
          );
        }
        final release = <String, Object>{
          'tag_name': 'v1.2.3',
          'published_at': '2026-09-01T00:00:00Z',
          'assets': <Object>[],
        };
        return http.Response(jsonEncode(kernel ? release : [release]), 200);
      });
      addTearDown(client.close);
      final Future<String> latest = kernel
          ? KernelUpdate.check(
              '1.2.2',
              client: client,
            ).then((update) => update.latest)
          : AppUpdate.check(client: client).then((update) => update.latest);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(await latest, '1.2.3');
      expect(attempts, 3);
    });
  }

  testWidgets('更新握手持续中断时仅在原有 10 秒内重试', (tester) async {
    int attempts = 0;
    final client = MockClient((_) async {
      attempts++;
      throw const HandshakeException('Connection terminated during handshake');
    });
    addTearDown(client.close);
    final Future<void> result = expectLater(
      AppUpdate.check(client: client),
      throwsA(isA<TimeoutException>()),
    );
    await tester.pump();
    for (int second = 1; second <= 10; second++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await result;
    expect(attempts, 10);
    await tester.pump(const Duration(seconds: 2));
    expect(attempts, 10);
  });

  for (final Exception error in <Exception>[
    const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
    const SocketException('Connection reset by peer'),
  ]) {
    test('更新请求不重试其他网络错误：$error', () async {
      int attempts = 0;
      final client = MockClient((_) async {
        attempts++;
        throw error;
      });
      addTearDown(client.close);
      await expectLater(AppUpdate.check(client: client), throwsA(same(error)));
      expect(attempts, 1);
    });
  }

  testWidgets('更新重试共用总时限，超时中断后不再发送请求', (tester) async {
    int attempts = 0;
    int aborted = 0;
    final client = MockClient.streaming((request, _) async {
      attempts++;
      (request as http.Abortable).abortTrigger!.then((_) => aborted++);
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      throw const HandshakeException('Connection terminated during handshake');
    });
    addTearDown(client.close);
    final Future<bool> result = GithubRelease.reachable(client);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2300));
    await tester.pump(const Duration(seconds: 1));
    expect(attempts, 2);
    await tester.pump(const Duration(milliseconds: 1700));
    expect(await result, isFalse);
    expect(aborted, 2);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(seconds: 2));
    expect(attempts, 2);
  });

  test('内核只读取最新正式版，不下载超过 4 MiB 的历史发布列表', () async {
    final Map<String, Object> release = <String, Object>{
      'tag_name': 'v1.2.3',
      'published_at': '2026-09-01T00:00:00Z',
      'prerelease': false,
      'assets': <Object>[],
      'body': 'x' * (160 * 1024),
    };
    final List<Uri> requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      return http.Response(
        jsonEncode(
          request.url.path.endsWith('/latest')
              ? release
              : List<Object>.filled(30, release),
        ),
        200,
      );
    });
    addTearDown(client.close);

    final KernelUpdate update = await KernelUpdate.check(
      '1.2.2',
      client: client,
    );
    expect(update.latest, '1.2.3');
    expect(update.outdated, isTrue);
    expect(requests.map((uri) => uri.toString()), <String>[
      'https://api.github.com/repos/MetaCubeX/mihomo/releases/latest',
    ]);
  });

  for (final String scenario in <String>[
    'draft',
    'prerelease',
    'invalid-tag',
    'invalid-date',
    'list',
  ]) {
    test('内核最新正式版拒绝无效元数据：$scenario', () async {
      final Map<String, Object> release = <String, Object>{
        'tag_name': scenario == 'invalid-tag' ? 'Prerelease-Alpha' : 'v1.2.3',
        'published_at': scenario == 'invalid-date'
            ? 'invalid'
            : '2026-09-01T00:00:00Z',
        'draft': scenario == 'draft',
        'prerelease': scenario == 'prerelease',
        'assets': <Object>[],
      };
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(scenario == 'list' ? <Object>[release] : release),
          200,
        );
      });
      addTearDown(client.close);
      await expectLater(
        KernelUpdate.check('1.2.2', client: client),
        throwsA(isA<GithubReleaseException>()),
      );
    });
  }

  for (final bool preIsTip in <bool>[true, false]) {
    test('软件仍按发布时间选择 Pre／Last 通道：Pre 最新=$preIsTip', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/repos/ECYCloud/ECYCloudClient/releases');
        expect(request.url.queryParameters['per_page'], '30');
        return http.Response(
          jsonEncode(<Object>[
            <String, Object>{
              'tag_name': 'v9.0.0',
              'published_at': '2026-08-01T00:00:00Z',
            },
            <String, Object>{
              'tag_name': 'v1.0.4-pre',
              'prerelease': true,
              'published_at': preIsTip
                  ? '2026-09-03T00:00:00Z'
                  : '2026-09-01T00:00:00Z',
            },
            <String, Object>{
              'tag_name': 'v1.0.2',
              'published_at': '2026-09-02T00:00:00Z',
            },
          ]),
          200,
        );
      });
      addTearDown(client.close);
      final AppUpdate update = await AppUpdate.check(client: client);
      expect(
        update.latest,
        AppConfig.appVersion.startsWith('Pre ') && preIsTip
            ? 'Pre 1.0.4'
            : '1.0.2',
      );
    });
  }

  for (final int status in <int>[403, 429, 503]) {
    test('GitHub HTTP $status 不重试、不回显响应正文', () async {
      int attempts = 0;
      final client = MockClient((request) async {
        attempts++;
        return http.Response(
          'private-response-marker',
          status,
          headers: <String, String>{'x-ratelimit-remaining': '0'},
        );
      });
      addTearDown(client.close);
      await expectLater(
        AppUpdate.check(client: client),
        throwsA(
          isA<GithubReleaseException>().having(
            (error) => error.message,
            'message',
            allOf(<Matcher>[
              contains('$status'),
              if (status != 503) contains('频繁'),
              isNot(contains('private')),
            ]),
          ),
        ),
      );
      expect(attempts, 1);
    });
  }

  for (final String scenario in <String>[
    'primary',
    'secondary',
    'both',
    'missing',
    'invalid',
    'expired',
    'forbidden',
  ]) {
    test('GitHub 限流恢复时间遵循响应头：$scenario', () async {
      final DateTime started = DateTime.now();
      final int reset = started.millisecondsSinceEpoch ~/ 1000 + 120;
      final Map<String, String> headers = switch (scenario) {
        'primary' => <String, String>{
          'x-ratelimit-remaining': '0',
          'x-ratelimit-reset': '$reset',
        },
        'secondary' => <String, String>{'retry-after': '30'},
        'both' => <String, String>{
          'x-ratelimit-remaining': '0',
          'x-ratelimit-reset': '$reset',
          'retry-after': '180',
        },
        'invalid' => <String, String>{
          'x-ratelimit-remaining': '0',
          'x-ratelimit-reset': 'invalid',
          'retry-after': '-1',
        },
        'expired' => <String, String>{
          'x-ratelimit-remaining': '0',
          'x-ratelimit-reset': '${reset - 240}',
        },
        _ => <String, String>{},
      };
      final client = MockClient((request) async {
        return http.Response(
          'private-response-marker',
          scenario == 'missing' || scenario == 'secondary' ? 429 : 403,
          headers: headers,
        );
      });
      addTearDown(client.close);
      GithubReleaseException? failure;
      try {
        await GithubRelease.list('example/fixture', client: client);
      } on GithubReleaseException catch (error) {
        failure = error;
      }
      expect(failure, isNotNull);
      expect(failure!.message, isNot(contains('private-response-marker')));
      if (scenario == 'forbidden') {
        expect(failure.retryAt, isNull);
        expect(failure.message, 'GitHub 返回 HTTP 403');
        return;
      }
      expect(failure.retryAt, isNotNull);
      final int seconds = failure.retryAt!.difference(started).inSeconds;
      final int expected = switch (scenario) {
        'primary' => 120,
        'secondary' => 30,
        'both' => 180,
        _ => 60,
      };
      expect(seconds, inInclusiveRange(expected - 1, expected + 1));
      expect(
        failure.message,
        contains(failure.retryAt!.toString().split('.').first),
      );
    });
  }

  test('更新元数据持续发送也必须在总时限结束并中断请求', () async {
    final Completer<void> aborted = Completer<void>();
    final StreamController<List<int>> body = StreamController<List<int>>();
    final Timer sender = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => body.add([32]),
    );
    final client = MockClient.streaming((request, _) async {
      (request as http.Abortable).abortTrigger!.then((_) {
        sender.cancel();
        aborted.complete();
        body.close();
      });
      return http.StreamedResponse(body.stream, 200);
    });
    addTearDown(() {
      sender.cancel();
      body.close();
      client.close();
    });
    final Stopwatch elapsed = Stopwatch()..start();
    expect(await GithubRelease.reachable(client), isFalse);
    await aborted.future;
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 8)));
  });

  for (final (bool, bool) sizes in <(bool, bool)>[
    (true, false),
    (false, false),
    (true, true),
    (false, true),
  ]) {
    final (bool declaredSize, bool latestStableOnly) = sizes;
    test('更新元数据超过 4 MiB 时拒绝并取消请求：$sizes', () async {
      final Completer<void> cancelled = Completer<void>();
      final client = MockClient.streaming((request, _) async {
        expect(request.followRedirects, isFalse);
        expect(request, isA<http.Abortable>());
        (request as http.Abortable).abortTrigger!.then(
          (_) => cancelled.complete(),
        );
        return http.StreamedResponse(
          Stream<List<int>>.value(List<int>.filled(4 * 1024 * 1024 + 1, 32)),
          200,
          contentLength: declaredSize ? 4 * 1024 * 1024 + 1 : null,
        );
      });
      addTearDown(client.close);
      await expectLater(
        GithubRelease.list(
          'example/fixture',
          client: client,
          latestStableOnly: latestStableOnly,
        ),
        throwsA(
          isA<GithubReleaseException>().having(
            (error) => error.message,
            'message',
            contains('超过 4 MiB'),
          ),
        ),
      );
      await cancelled.future;
    });
  }

  test('正常更新元数据可解析，HTTP 跳转不能成为更新来源', () async {
    int status = 200;
    final client = MockClient.streaming((request, _) async {
      expect(request.followRedirects, isFalse);
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            jsonEncode([
              {
                'tag_name': 'v1.2.3',
                'published_at': '2026-09-01T00:00:00Z',
                'assets': [],
              },
            ]),
          ),
        ),
        status,
        headers: {'location': 'http://untrusted.example.test/releases'},
      );
    });
    addTearDown(client.close);
    expect(
      (await GithubRelease.list(
        'example/fixture',
        client: client,
      )).single.version,
      '1.2.3',
    );
    status = 302;
    await expectLater(
      GithubRelease.list('example/fixture', client: client),
      throwsA(isA<GithubReleaseException>()),
    );
  });

  test('同通道按号段比大小', () {
    expect(at('1.0.2', '1.0.3').outdated, isTrue);
    expect(at('1.0.2', '1.0.2').outdated, isFalse);
    expect(at('1.0.3', '1.0.2').outdated, isFalse);

    expect(at('Pre 1.0.2', 'Pre 1.0.3').outdated, isTrue);
    expect(at('Pre 1.0.3', 'Pre 1.0.3').outdated, isFalse);
    expect(at('Pre 1.0.4', 'Pre 1.0.3').outdated, isFalse);
  });

  test('Pre 落回 Last 是通道切换，正式版号段更低也要更新', () {
    expect(at('Pre 1.0.3', '1.0.1').outdated, isTrue);
    expect(at('Pre 1.0.1', '1.0.1').outdated, isTrue);
  });

  test('调试构建的 dev 版本不会被判成过时', () {
    expect(at('dev', '1.0.3').outdated, isFalse);
  });
}
