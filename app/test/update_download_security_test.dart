import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ecycloud_client/core/app_paths.dart';
import 'package:ecycloud_client/domain/platform/platform_service.dart';
import 'package:ecycloud_client/domain/update/app_update.dart';
import 'package:ecycloud_client/state/connection_controller.dart';
import 'package:ecycloud_client/state/update_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Connection extends ChangeNotifier implements ConnectionController {
  @override
  ConnectionPhase get state => ConnectionPhase.disconnected;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Platform implements PlatformService {
  List<int>? installedBytes;
  @override
  Future<bool> runInstaller(String path) async {
    installedBytes = await File(path).readAsBytes();
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final String scenario in <String>[
    'normal',
    'metadata-too-large',
    'metadata-missing-size',
    'metadata-invalid-digest',
    'header-too-large',
    'stream-too-large',
    'truncated',
    'stream-error',
    'digest-mismatch',
    'unsafe-redirect',
    'redirect-loop',
    'safe-redirect',
  ]) {
    test('安装包下载边界、校验和失败清理：$scenario', () async {
      final List<int> bytes = <int>[1, 2, 3, 4];
      final String name = 'ECYCloud-999.0.0-${AppUpdate.assetSuffix}';
      final String url = '${AppUpdate.downloadPrefix}v999.0.0/$name';
      final _Connection connection = _Connection();
      final _Platform platform = _Platform();
      final UpdateController controller = UpdateController(
        connection: connection,
        platform: platform,
      );
      addTearDown(controller.dispose);
      addTearDown(connection.dispose);
      final File target = File('${AppPaths.updates.path}/$name');
      await target.writeAsString('previous verified file');
      final File partial = File('${target.path}.part');
      await partial.writeAsString('previous interrupted download');
      int downloads = 0;
      final bool badMetadata = scenario.startsWith('metadata-');
      final bool success = scenario == 'normal' || scenario == 'safe-redirect';

      Future<http.StreamedResponse> respond(http.BaseRequest request, _) async {
        if (request.url.host == 'api.github.com') {
          final String metadata = jsonEncode(<Object>[
            <String, Object>{
              'tag_name': 'v999.0.0',
              'published_at': '2026-09-18T00:00:00Z',
              'prerelease': false,
              'assets': <Object>[
                <String, Object>{
                  'name': name,
                  'browser_download_url': url,
                  if (scenario != 'metadata-missing-size')
                    'size': scenario == 'metadata-too-large'
                        ? (1 << 30) + 1
                        : bytes.length,
                  'digest': scenario == 'metadata-invalid-digest'
                      ? 'sha256:invalid'
                      : 'sha256:${sha256.convert(bytes)}',
                },
              ],
            },
          ]);
          return http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode(metadata)),
            200,
          );
        }
        downloads++;
        expect(request.followRedirects, isFalse);
        if (scenario == 'redirect-loop' ||
            (downloads == 1 &&
                (scenario == 'unsafe-redirect' ||
                    scenario == 'safe-redirect'))) {
          return http.StreamedResponse(
            const Stream<List<int>>.empty(),
            302,
            isRedirect: true,
            headers: <String, String>{
              'location': scenario == 'unsafe-redirect'
                  ? 'http://untrusted.test/file'
                  : 'https://release-assets.githubusercontent.com/file',
            },
          );
        }
        if (scenario == 'stream-error') {
          return http.StreamedResponse(
            Stream<List<int>>.error(
              const SocketException('synthetic interruption'),
            ),
            200,
          );
        }
        final List<int> content = switch (scenario) {
          'stream-too-large' => <int>[...bytes, 5],
          'truncated' => <int>[1, 2],
          'digest-mismatch' => <int>[4, 3, 2, 1],
          _ => bytes,
        };
        return http.StreamedResponse(
          Stream<List<int>>.value(content),
          200,
          contentLength: scenario == 'header-too-large'
              ? bytes.length + 1
              : null,
        );
      }

      await http.runWithClient(() async {
        await controller.checkApp();
        expect(controller.appUpdate?.installer, isNotNull);
        await controller.installApp();
      }, () => MockClient.streaming(respond));

      expect(platform.installedBytes, success ? bytes : isNull);
      expect(
        await target.readAsBytes(),
        success ? bytes : utf8.encode('previous verified file'),
      );
      if (badMetadata) {
        expect(downloads, 0);
        // 元数据被拒绝时不触碰上一次下载；开始新下载后才清理同名临时文件。
        expect(await partial.readAsString(), 'previous interrupted download');
      } else {
        expect(await partial.exists(), isFalse);
      }
      if (scenario == 'unsafe-redirect') expect(downloads, 1);
      if (scenario == 'redirect-loop') expect(downloads, 6);
      await target.delete();
      if (await partial.exists()) await partial.delete();
    });
  }
}
