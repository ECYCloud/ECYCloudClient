import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:ecycloud_client/data/api/panel_api_client.dart';
import 'package:ecycloud_client/data/models/announcement.dart';
import 'package:ecycloud_client/data/store/json_file_store.dart';
import 'package:ecycloud_client/l10n/app_language.dart';
import 'package:ecycloud_client/l10n/l10n.dart';
import 'package:ecycloud_client/state/announcement_controller.dart';
import 'package:ecycloud_client/data/models/account.dart';
import 'package:ecycloud_client/data/models/ticket.dart';
import 'package:ecycloud_client/ui/node_labels.dart';
import 'package:flutter_test/flutter_test.dart';

class _DelayedAnnouncements extends PanelApiClient {
  _DelayedAnnouncements()
    : super(
        baseUrl: 'https://fixture.test',
        configBaseUrl: 'https://fixture.test',
        device: const DeviceInfo(
          platform: 'windows',
          deviceId: 'fixture',
          deviceName: '',
          deviceModel: '',
          osVersion: '',
          appVersion: '',
        ),
      );

  final List<Completer<AnnouncementBundle>> requests =
      <Completer<AnnouncementBundle>>[];

  @override
  Future<AnnouncementBundle> fetchAnnouncements() {
    final Completer<AnnouncementBundle> request =
        Completer<AnnouncementBundle>();
    requests.add(request);
    return request.future;
  }
}

AnnouncementBundle _bundle(String title) => AnnouncementBundle(
  items: <Announcement>[
    Announcement(
      id: 2,
      title: title,
      date: '2026-01-01',
      updatedAt: '2026-01-01',
      content: '<p>fixture</p>',
    ),
  ],
);

void main() {
  test('工单只翻译缺失姓名时的角色标签，真实姓名保持原文', () {
    L10n.current = AppLanguage.en;
    expect(
      TicketMessage.fromJson(<String, dynamic>{'id': 1, 'user_name': '设置'})
          .userName,
      '设置',
    );
    expect(
      TicketMessage.fromJson(<String, dynamic>{'id': 1, 'is_admin': true})
          .userName,
      'Admin',
    );
    expect(TicketMessage.fromJson(<String, dynamic>{'id': 1}).userName, 'Me');
  });
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('content-language-test-');
    L10n.current = AppLanguage.zhCN;
  });
  tearDown(() {
    L10n.current = AppLanguage.zhCN;
    NodeLabels.configure('');
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('节点和策略组译名只影响显示，原始标识与保存值保持不变', () {
    NodeLabels.configure(
      '',
      <String, String>{'node-9': 'Fixture node'},
      <String, String>{'主节点': 'Main nodes', 'Google服务': 'Google services'},
    );
    expect(NodeLabels.displayName('node-9'), 'Fixture node');
    expect(NodeLabels.displayName('主节点'), 'Main nodes');
    expect(NodeLabels.displayName('Google服务'), 'Google services');
    expect(NodeLabels.originalName('主节点'), '主节点');
    expect(NodeLabels.officialId('node-9'), 9);
    expect(NodeLabels.displayName('自定义名称'), '自定义名称');
    final SubscriptionConfig config = SubscriptionConfig.fromJson(
      <String, dynamic>{
        'all_group_names': <String>['主节点'],
        'disabled_groups': <String>['主节点'],
        'group_labels': <String, String>{'主节点': 'Main nodes'},
      },
    );
    expect(config.groupLabels['主节点'], 'Main nodes');
    expect(config.allGroupNames, <String>['主节点']);
    expect(config.disabledGroups, <String>['主节点']);
    NodeLabels.configure('');
    expect(NodeLabels.displayName('主节点'), '主节点');
  });

  test('请求公告、商品和条款时传递当前语言', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    final List<String?> languages = <String?>[];
    server.listen((HttpRequest request) async {
      languages.add(request.headers.value('Accept-Language'));
      request.response.headers.contentType = ContentType.json;
      final Object data = request.uri.path.endsWith('/announcements')
          ? <String, Object>{'announcements': <Object>[]}
          : request.uri.path.endsWith('/products')
          ? <String, Object>{'products': <Object>[]}
          : <String, Object>{'content': '<p>fixture</p>'};
      request.response.write(
        jsonEncode(<String, Object>{'ret': 1, 'data': data}),
      );
      await request.response.close();
    });
    final String origin = 'http://127.0.0.1:${server.port}';
    final PanelApiClient api = PanelApiClient(
      baseUrl: origin,
      configBaseUrl: origin,
      device: const DeviceInfo(
        platform: 'windows',
        deviceId: 'fixture',
        deviceName: '',
        deviceModel: '',
        osVersion: '',
        appVersion: '',
      ),
    );
    addTearDown(api.close);
    for (final AppLanguage language in <AppLanguage>[
      ...AppLanguage.values,
      AppLanguage.resolve(stored: '', device: const Locale('ja', 'JP')),
      AppLanguage.resolve(stored: 'zh_TW', device: const Locale('ja', 'JP')),
    ]) {
      L10n.current = language;
      await api.fetchAnnouncements();
      await api.fetchShopProducts();
      await api.fetchTos();
    }
    expect(languages, <String>[
      'zh-CN',
      'zh-CN',
      'zh-CN',
      'zh-TW',
      'zh-TW',
      'zh-TW',
      'en-US',
      'en-US',
      'en-US',
      'en-US',
      'en-US',
      'en-US',
      'zh-TW',
      'zh-TW',
      'zh-TW',
    ]);
  });

  test('官方配置请求和响应把策略组译名送到节点、日志及运行配置展示', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    final List<String?> languages = <String?>[];
    server.listen((HttpRequest request) async {
      expect(request.uri.path, '/api/client/v1/config/clash');
      expect(request.headers.value('X-ECY-Node-Providers'), '1');
      final String? language = request.headers.value('Accept-Language');
      languages.add(language);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object>{
          'ret': 1,
          'data': <String, Object>{
            'config': <String, Object>{
              'proxy-groups': <Object>[
                <String, Object>{
                  'name': '主节点',
                  'type': 'select',
                  'proxies': <String>['node-9'],
                },
              ],
              'rules': <String>['MATCH,主节点'],
            },
            'group_labels': <String, String>{
              '主节点': language == 'en-US' ? 'Main nodes' : '主節點',
            },
            'node_labels': <String, String>{'node-9': 'Fixture node'},
          },
        }),
      );
      await request.response.close();
    });
    final String origin = 'http://127.0.0.1:${server.port}';
    final PanelApiClient api = PanelApiClient(
      baseUrl: origin,
      configBaseUrl: origin,
      device: const DeviceInfo(
        platform: 'windows',
        deviceId: 'fixture',
        deviceName: '',
        deviceModel: '',
        osVersion: '',
        appVersion: '',
      ),
    );
    addTearDown(api.close);
    for (final AppLanguage language in <AppLanguage>[
      AppLanguage.en,
      AppLanguage.zhTW,
    ]) {
      L10n.current = language;
      final RemoteProfile remote = await api.fetchClashProfile();
      NodeLabels.configure(
        remote.flagRegex,
        remote.nodeLabels,
        remote.groupLabels,
      );
      final String label = language == AppLanguage.en ? 'Main nodes' : '主節點';
      expect(NodeLabels.displayName('主节点'), label);
      expect(
        NodeLabels.annotateText('Match using 主节点[node-9]'),
        'Match using $label[Fixture node]',
      );
      expect(
        NodeLabels.annotateRuntimeConfig(jsonEncode(remote.config)),
        contains('MATCH,$label'),
      );
      expect(remote.config['rules'], <String>['MATCH,主节点']);
    }
    expect(languages, <String>['en-US', 'zh-TW']);
  });

  test('切换语言时丢弃旧公告响应，旧请求不能结束新请求的加载状态', () async {
    final _DelayedAnnouncements api = _DelayedAnnouncements();
    addTearDown(api.close);
    final AnnouncementController controller = AnnouncementController(
      store: JsonFileStore(File('${temp.path}/announcement.json'), 'fixture'),
    );
    addTearDown(controller.dispose);
    controller.attachApi(api);
    final Future<void> oldRequest = controller.refresh();
    L10n.current = AppLanguage.en;
    controller.languageChanged();
    final Future<void> newRequest = controller.refresh();
    api.requests[0].complete(_bundle('旧语言'));
    await oldRequest;
    expect(controller.items, isEmpty);
    expect(controller.busy, isTrue);
    api.requests[1].complete(_bundle('fixture-en'));
    await newRequest;
    expect(controller.items.single.title, 'fixture-en');
    expect(controller.busy, isFalse);
  });
}
