import 'package:ecycloud_client/ui/node_labels.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('地区按面板下发的取词正则 + 随包映射表认出来', () async {
    await NodeLabels.load();
    NodeLabels.configure(r'/[\p{L}\p{N}]+/u');
    await NodeLabels.warmRegions(<String>[
      '香港 Ⅱ · D1',
      'us 美国 X · A1 [VLESS]',
      'FR-Paris-1',
      '巴哈姆特专线',
    ]);

    expect(NodeLabels.region('香港 Ⅱ · D1'), 'hk');
    expect(NodeLabels.region('us 美国 X · A1 [VLESS]'), 'us');
    expect(NodeLabels.region('FR-Paris-1'), 'fr');
    expect(NodeLabels.region('巴哈姆特专线'), isNull);
  });

  test('恶意取词正则不拖住界面：后台超时后放弃旗帜，正常正则仍可用', () async {
    await NodeLabels.load();

    // 灾难性回溯模式：若在界面 isolate 同步跑，单次匹配可达数十秒
    NodeLabels.configure(r'/(a+)+$/');
    final Stopwatch watch = Stopwatch()..start();
    await NodeLabels.warmRegions(<String>['${'a' * 40}!']);
    watch.stop();
    // 后台 isolate 带 2 秒硬超时并强杀，warmRegions 必须在可接受时间内返回
    expect(
      watch.elapsed,
      lessThan(const Duration(seconds: 8)),
      reason: '取词正则必须在后台 isolate 内带硬超时，不能拖住调用方',
    );
    expect(
      NodeLabels.region('${'a' * 40}!'),
      isNull,
      reason: '超时的取词正则本轮不显示旗帜，且 region() 绝不同步跑该正则',
    );

    // 良性正则重新配置后照常识别地区
    NodeLabels.configure(r'/[\p{L}\p{N}]+/u');
    await NodeLabels.warmRegions(<String>['美国 X · A1']);
    expect(NodeLabels.region('美国 X · A1'), 'us');

    NodeLabels.configure(r'/[\p{L}\p{N}]+/u');
  });

  test('名字自带国旗 emoji 时直接反推代码，不查表', () async {
    await NodeLabels.load();

    expect(NodeLabels.region('🇭🇰HK01'), 'hk');
    expect(NodeLabels.region('🇯🇵 Japan 01'), 'jp');
    expect(NodeLabels.region('Japan 01'), isNull);
  });

  test('展示名去掉国旗 emoji，地区只由旗帜图标表达', () {
    expect(NodeLabels.displayName('🇹🇼 台湾 Ⅱ · A1 [CF]'), '台湾 Ⅱ · A1 [CF]');
    expect(
      NodeLabels.originalName('🇹🇼 台湾 Ⅱ · A1 [CF]'),
      '🇹🇼 台湾 Ⅱ · A1 [CF]',
    );
    expect(NodeLabels.displayName('🇺🇸美国 Ⅲ · B2'), '美国 Ⅲ · B2');
    expect(NodeLabels.displayName('香港 Ⅱ · D1'), '香港 Ⅱ · D1');
    expect(NodeLabels.displayName('🇯🇵'), '🇯🇵');
  });

  test('面板按 node-{id} 命名 proxy 时，显示名与地区都从映射表取', () async {
    await NodeLabels.load();
    NodeLabels.configure(r'/[\p{L}\p{N}]+/u', <String, String>{
      'node-12': '🇭🇰 香港 01',
      'node-34': '日本 02',
    });

    expect(NodeLabels.displayName('node-12'), '香港 01');
    expect(NodeLabels.displayName('node-34'), '日本 02');
    expect(NodeLabels.region('node-12'), 'hk');
    expect(NodeLabels.displayName('主节点'), '主节点');
    expect(NodeLabels.displayName('DIRECT'), 'DIRECT');
    expect(NodeLabels.displayName('node-99'), '');
    expect(NodeLabels.originalName('node-99'), '');

    NodeLabels.configure(r'/[\p{L}\p{N}]+/u');
  });

  test('运行配置展示只留显示名，不出现 node-{id}', () {
    NodeLabels.configure(r'/[\p{L}\p{N}]+/u', <String, String>{
      'node-12': '🇭🇰 香港 01',
      'node-1': '备用',
    });

    const String raw = '''
{
  "proxies": [
    {"name": "node-12", "type": "ss"},
    {"name": "node-1", "type": "ss"},
    {"name": "node-99", "type": "ss"}
  ],
  "proxy-groups": [
    {"name": "主节点", "proxies": ["node-12", "DIRECT"]}
  ],
  "rules": ["DOMAIN,x.com,node-12", "MATCH,主节点"]
}''';

    final String shown = NodeLabels.annotateRuntimeConfig(raw);
    expect(shown, contains('"香港 01"'));
    expect(shown, contains('"备用"'));
    expect(shown, contains('DOMAIN,x.com,香港 01'));
    expect(shown, contains('"DIRECT"'));
    expect(shown, contains('"MATCH,主节点"'));
    expect(shown, isNot(contains(RegExp(r'node-\d+'))));

    NodeLabels.configure(r'/[\p{L}\p{N}]+/u');
  });

  test('内核日志把 node-{id} 换成节点名，不误伤更长的 id', () {
    NodeLabels.configure(r'/[\p{L}\p{N}]+/u', <String, String>{
      'node-120': '🇭🇰 香港 01',
      'node-12': '备用',
    });

    expect(
      NodeLabels.annotateText(
        '[TCP] 198.18.0.1:23016(ECYCloud.exe) --> owo.ecycloud.com:443 '
        'match Match using 主节点[node-120]',
      ),
      contains('主节点[香港 01]'),
    );
    expect(NodeLabels.annotateText('node-12 and node-120'), '备用 and 香港 01');
    expect(NodeLabels.annotateText('DIRECT'), 'DIRECT');
    expect(
      NodeLabels.annotateText('Match using 主节点[node-120]'),
      isNot(contains('node-120')),
    );
    expect(
      NodeLabels.annotateText('match Match using 主节点[node-99]'),
      isNot(contains(RegExp(r'node-\d+'))),
    );

    NodeLabels.configure(r'/[\p{L}\p{N}]+/u');
    expect(
      NodeLabels.annotateText('Match using 主节点[node-12]'),
      isNot(contains(RegExp(r'node-\d+'))),
    );
  });

  test('下发的策略组译名覆盖日志和运行配置展示，不改写原始配置', () {
    NodeLabels.configure(
      '',
      <String, String>{'node-9': 'Fixture node'},
      <String, String>{'主节点': 'Main nodes', 'Google服务': 'Google services'},
    );
    addTearDown(() => NodeLabels.configure(''));
    expect(
      NodeLabels.annotateText('Match using Google服务[主节点[node-9]]'),
      'Match using Google services[Main nodes[Fixture node]]',
    );
    expect(
      NodeLabels.annotateText('Match using 主节点备份[node-9]'),
      'Match using 主节点备份[Fixture node]',
    );
    const String raw =
        '{"proxy-groups":[{"name":"主节点","proxies":["node-9"]},'
        '{"name":"Google服务","proxies":["主节点"]}],'
        '"rules":["MATCH,Google服务"]}';
    final String shown = NodeLabels.annotateRuntimeConfig(raw);
    expect(shown, contains('"name":"Main nodes"'));
    expect(shown, contains('"proxies":["Main nodes"]'));
    expect(shown, contains('"MATCH,Google services"'));
    expect(shown, isNot(contains('主节点')));
    expect(raw, contains('"MATCH,Google服务"'));
  });

  test('随包素材按文件名即标识的约定取得到', () async {
    final AssetManifest manifest = await AssetManifest.loadFromAssetBundle(
      rootBundle,
    );
    final List<String> assets = manifest
        .listAssets()
        .where((String key) => key.startsWith('assets/'))
        .toList(growable: false);

    expect(
      assets.where((String key) => key.startsWith('assets/flags/')),
      isNotEmpty,
    );

    for (final String asset in assets) {
      final ByteData data = await rootBundle.load(asset);
      expect(data.lengthInBytes, greaterThan(0), reason: asset);
    }
  });
}
