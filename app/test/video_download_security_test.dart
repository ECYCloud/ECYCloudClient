import 'dart:io';

import 'package:ecycloud_client/core/app_paths.dart';
import 'package:ecycloud_client/ui/widgets/icon_image.dart';
import 'package:ecycloud_client/ui/widgets/video_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

const List<int> _video = <int>[0, 0, 0, 24, 102, 116, 121, 112];

void main() {
  final HttpOverrides? previousHttpOverrides = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = previousHttpOverrides);
  late HttpServer server;
  late String origin;
  late int requests;

  setUp(() async {
    HtmlVideoView.resumeSession();
    requests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    server.listen((HttpRequest request) async {
      requests++;
      request.response.contentLength = _video.length;
      request.response.add(_video);
      await request.response.close();
    });
  });
  tearDown(() async {
    await HtmlVideoView.clearSession();
    await server.close(force: true);
  });

  // 预算用完时点击也不建播放器：测试环境里没有 libmpv，这条路径不碰播放器
  testWidgets('富文本视频点击前不建播放器也不发请求，预算用完后点击直接显示失败', (WidgetTester tester) async {
    addTearDown(RemoteIcon.clearSession);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: HtmlVideoView('$origin/video'))),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(Video), findsNothing);
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    expect(find.text('无法播放视频'), findsNothing);

    RemoteIcon.chargeMedia(200 << 20);
    await tester.tap(find.byIcon(Icons.play_circle_outline));
    await tester.pump();
    expect(find.text('无法播放视频'), findsOneWidget);
    expect(find.byType(Video), findsNothing);
    expect(requests, 0);
    expect(AppPaths.videoCache.listSync(), isEmpty);
  });
}
