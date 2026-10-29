import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ecycloud_client/core/app_paths.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/domain/update/app_update.dart';
import 'package:ecycloud_client/domain/update/github_release.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:ecycloud_client/state/update_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Connection extends ChangeNotifier implements ConnectionController {
  @override
  ConnectionPhase state = ConnectionPhase.disconnected;

  @override
  AppSettings settings = const AppSettings.defaults();

  Future<String> Function()? readVersion;

  @override
  Future<String> kernelVersion() =>
      readVersion?.call() ?? Future<String>.value('1.0.0');

  void setConnected(bool connected) {
    state = connected
        ? ConnectionPhase.connected
        : ConnectionPhase.disconnected;
    notifyListeners();
  }

  void refreshStats() => notifyListeners();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Platform implements PlatformService {
  String? installerPath;

  @override
  Future<bool> runInstaller(String path) async {
    installerPath = path;
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HttpClient implements HttpClient {
  _HttpClient(this.onRequest);

  final Future<void> Function() onRequest;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    await onRequest();
    throw const SocketException('synthetic update failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  for (final int limitedRequest in <int>[1, 2]) {
    testWidgets('第 $limitedRequest 个检查遇到限流后共用等待并自动恢复', (tester) async {
      final _Connection connection = _Connection()..setConnected(true);
      final UpdateController controller = UpdateController(
        connection: connection,
        platform: _Platform(),
      );
      int requests = 0;
      final GithubReleaseException limited = GithubReleaseException(
        'GitHub 请求过于频繁（HTTP 403），一分钟后重试',
        retryAt: DateTime.now().add(const Duration(minutes: 1)),
      );

      try {
        await HttpOverrides.runZoned(
          () async {
            controller.start();
            await tester.pump();
            expect(requests, limitedRequest);
            expect(controller.appStatus, contains(limited.message));
            expect(controller.kernelStatus, controller.appStatus);
            await controller.checkApp();
            await controller.checkKernel();
            await controller.checkAll();
            expect(await controller.githubReachable(), isFalse);
            expect(requests, limitedRequest);
            await tester.pump(const Duration(seconds: 30));
            connection.setConnected(false);
            connection.setConnected(true);
            await tester.pump();
            expect(requests, limitedRequest);
            await tester.pump(const Duration(seconds: 30));
            expect(requests, limitedRequest);
            await tester.pump(const Duration(seconds: 2));
            expect(requests, limitedRequest + 2);
            connection.refreshStats();
            await tester.pump();
            expect(requests, limitedRequest + 2);
          },
          createHttpClient: (_) => _HttpClient(() async {
            requests++;
            if (requests == limitedRequest) throw limited;
          }),
        );
      } finally {
        controller.dispose();
        connection.dispose();
      }
    });
  }

  testWidgets('限流到期时检查仍在途，结束后补查且不并发', (tester) async {
    final _Connection connection = _Connection();
    final UpdateController controller = UpdateController(
      connection: connection,
      platform: _Platform(),
    );
    final Completer<void> release = Completer<void>();
    connection.readVersion = () async {
      await release.future;
      return '1.0.0';
    };
    int requests = 0;
    try {
      await HttpOverrides.runZoned(
        () async {
          final Future<void> checking = controller.checkAll();
          await tester.pump();
          expect(requests, 1);
          await controller.checkApp();
          expect(requests, 2);
          await tester.pump(const Duration(seconds: 62));
          expect(requests, 2);
          release.complete();
          await checking;
          await tester.pump();
          expect(requests, 5);
        },
        createHttpClient: (_) => _HttpClient(() async {
          requests++;
          if (requests == 2) {
            throw GithubReleaseException(
              'GitHub 请求过于频繁（HTTP 429）',
              retryAt: DateTime.now().add(const Duration(minutes: 1)),
            );
          }
        }),
      );
    } finally {
      if (!release.isCompleted) release.complete();
      controller.dispose();
      connection.dispose();
    }
  });

  testWidgets('销毁更新控制器会取消限流恢复', (tester) async {
    final _Connection connection = _Connection();
    final UpdateController controller = UpdateController(
      connection: connection,
      platform: _Platform(),
    );
    int requests = 0;
    await HttpOverrides.runZoned(
      () async {
        await controller.checkApp();
        expect(requests, 1);
        controller.dispose();
        connection.dispose();
        await tester.pump(const Duration(minutes: 2));
        expect(requests, 1);
      },
      createHttpClient: (_) => _HttpClient(() async {
        requests++;
        throw GithubReleaseException(
          'GitHub 请求过于频繁（HTTP 403）',
          retryAt: DateTime.now().add(const Duration(minutes: 1)),
        );
      }),
    );
  });

  for (final bool kernel in <bool>[false, true]) {
    testWidgets('销毁后才收到限流响应不创建恢复任务：内核 $kernel', (tester) async {
      final _Connection connection = _Connection();
      final UpdateController controller = UpdateController(
        connection: connection,
        platform: _Platform(),
      );
      final Completer<void> release = Completer<void>();
      int requests = 0;
      await HttpOverrides.runZoned(
        () async {
          final Future<void> checking = kernel
              ? controller.checkKernel()
              : controller.checkApp();
          await tester.pump();
          expect(requests, 1);
          controller.dispose();
          connection.dispose();
          release.complete();
          await checking;
          await tester.pump(const Duration(minutes: 2));
          await controller.checkAll();
          expect(requests, 1);
        },
        createHttpClient: (_) => _HttpClient(() async {
          requests++;
          await release.future;
          throw GithubReleaseException(
            'GitHub 请求过于频繁（HTTP 403）',
            retryAt: DateTime.now().add(const Duration(minutes: 1)),
          );
        }),
      );
    });
  }

  test('GitHub API 限流不阻断已获取安装包的下载', () async {
    final _Connection connection = _Connection();
    final _Platform platform = _Platform();
    final UpdateController controller = UpdateController(
      connection: connection,
      platform: platform,
    );
    final List<int> bytes = <int>[1, 2, 3, 4];
    final String name = 'ECYCloud-998.0.0-${AppUpdate.assetSuffix}';
    final String url = '${AppUpdate.downloadPrefix}v998.0.0/$name';
    final File target = File(
      '${AppPaths.updates.path}${Platform.pathSeparator}$name',
    );
    final File partial = File('${target.path}.part');
    int requests = 0;
    int downloads = 0;
    try {
      await http.runWithClient(
        () async {
          await controller.checkApp();
          expect(controller.appUpdate?.installer, isNotNull);
          await controller.checkKernel();
          expect(controller.appStatus, contains('HTTP 403'));
          await controller.installApp();
        },
        () => MockClient((request) async {
          if (request.url.host != 'api.github.com') {
            downloads++;
            expect(request.url.toString(), url);
            return http.Response.bytes(bytes, 200);
          }
          requests++;
          if (requests == 2) {
            return http.Response(
              '',
              403,
              headers: <String, String>{
                'x-ratelimit-remaining': '0',
                'retry-after': '60',
              },
            );
          }
          return http.Response(
            jsonEncode(<Object>[
              <String, Object>{
                'tag_name': 'v998.0.0',
                'published_at': '2026-09-18T00:00:00Z',
                'prerelease': false,
                'assets': <Object>[
                  <String, Object>{
                    'name': name,
                    'browser_download_url': url,
                    'size': bytes.length,
                    'digest': 'sha256:${sha256.convert(bytes)}',
                  },
                ],
              },
            ]),
            200,
          );
        }),
      );
      expect(requests, 2);
      expect(downloads, 1);
      expect(platform.installerPath, target.path);
      expect(await target.readAsBytes(), bytes);
    } finally {
      controller.dispose();
      connection.dispose();
      if (await target.exists()) await target.delete();
      if (await partial.exists()) await partial.delete();
    }
  });

  test('已连接失败不随状态刷新重试，手动与重新连接仍可补查', () async {
    final _Connection connection = _Connection()..setConnected(true);
    final UpdateController controller = UpdateController(
      connection: connection,
      platform: _Platform(),
    );
    addTearDown(controller.dispose);
    addTearDown(connection.dispose);
    int requests = 0;

    await HttpOverrides.runZoned(() async {
      controller.start();
      await _settle();
      expect(requests, 2);
      for (int i = 0; i < 3; i++) {
        connection.refreshStats();
        await _settle();
      }
      expect(requests, 2);
      await controller.checkAll();
      expect(requests, 4);
      connection.setConnected(false);
      await _settle();
      expect(requests, 4);
      connection.setConnected(true);
      await _settle();
      expect(requests, 6);
      connection.refreshStats();
      await _settle();
      expect(requests, 6);
    }, createHttpClient: (_) => _HttpClient(() async => requests++));
  });

  test('离线检查失败后恢复连接只补查一次', () async {
    final _Connection connection = _Connection();
    final UpdateController controller = UpdateController(
      connection: connection,
      platform: _Platform(),
    );
    addTearDown(controller.dispose);
    addTearDown(connection.dispose);
    int requests = 0;

    await HttpOverrides.runZoned(() async {
      controller.start();
      await _settle();
      expect(requests, 2);
      connection.refreshStats();
      await _settle();
      expect(requests, 2);
      connection.setConnected(true);
      await _settle();
      expect(requests, 4);
      connection.refreshStats();
      await _settle();
      expect(requests, 4);
    }, createHttpClient: (_) => _HttpClient(() async => requests++));
  });

  for (final scenario in <({int request, bool connected})>[
    (request: 1, connected: false),
    (request: 2, connected: false),
    (request: 1, connected: true),
    (request: 2, connected: true),
  ]) {
    test(
      '第 ${scenario.request} 个检查在途恢复不丢失或并发重试，起始连接：${scenario.connected}',
      () async {
        final _Connection connection = _Connection()
          ..setConnected(scenario.connected);
        final UpdateController controller = UpdateController(
          connection: connection,
          platform: _Platform(),
        );
        addTearDown(controller.dispose);
        addTearDown(connection.dispose);
        final Completer<void> entered = Completer<void>();
        final Completer<void> release = Completer<void>();
        int requests = 0;

        await HttpOverrides.runZoned(
          () async {
            controller.start();
            await entered.future;
            if (scenario.connected) connection.setConnected(false);
            connection.setConnected(true);
            connection.refreshStats();
            await _settle();
            expect(requests, scenario.request);
            release.complete();
            await _settle();
            expect(requests, 4);
            connection.refreshStats();
            await _settle();
            expect(requests, 4);
          },
          createHttpClient: (_) => _HttpClient(() async {
            requests++;
            if (requests == scenario.request) {
              entered.complete();
              await release.future;
            }
          }),
        );
      },
    );
  }

  test('已连接的请求中途断开失败，恢复后仍补查一次', () async {
    final _Connection connection = _Connection()..setConnected(true);
    final UpdateController controller = UpdateController(
      connection: connection,
      platform: _Platform(),
    );
    addTearDown(controller.dispose);
    addTearDown(connection.dispose);
    final Completer<void> entered = Completer<void>();
    final Completer<void> release = Completer<void>();
    int requests = 0;

    await HttpOverrides.runZoned(
      () async {
        controller.start();
        await entered.future;
        connection.setConnected(false);
        release.complete();
        await _settle();
        expect(requests, 2);
        connection.setConnected(true);
        await _settle();
        expect(requests, 4);
        connection.refreshStats();
        await _settle();
        expect(requests, 4);
      },
      createHttpClient: (_) => _HttpClient(() async {
        requests++;
        if (requests == 1) {
          entered.complete();
          await release.future;
        }
      }),
    );
  });
}
