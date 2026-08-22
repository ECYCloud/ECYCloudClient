import 'package:ecycloud_client/ui/node_labels.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('地区按面板下发的取词正则 + 随包映射表认出来', () async {
    await NodeLabels.load();
    // 正则由面板 /config/clash 下发，测试里直接给面板设置项的原文
    NodeLabels.configure(r'/[\p{L}\p{N}]+/u');

    expect(NodeLabels.region('香港 Ⅱ · D1'), 'hk');
    expect(NodeLabels.region('us 美国 X · A1 [VLESS]'), 'us');
    expect(NodeLabels.region('FR-Paris-1'), 'fr');
    expect(NodeLabels.region('巴哈姆特专线'), isNull);
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

    // 内核里的身份是 ID，界面上不能露出来
    expect(NodeLabels.displayName('node-12'), '香港 01');
    expect(NodeLabels.displayName('node-34'), '日本 02');
    expect(NodeLabels.region('node-12'), 'hk');
    expect(NodeLabels.displayName('主节点'), '主节点');
    expect(NodeLabels.displayName('DIRECT'), 'DIRECT');

    NodeLabels.configure(r'/[\p{L}\p{N}]+/u');
  });

  test('运行配置展示把 node-{id} 附上显示名，不碰未映射项', () {
    NodeLabels.configure(r'/[\p{L}\p{N}]+/u', <String, String>{
      'node-12': '🇭🇰 香港 01',
      'node-1': '备用',
    });

    const String raw = '''
{
  "proxies": [
    {"name": "node-12", "type": "ss"},
    {"name": "node-1", "type": "ss"}
  ],
  "proxy-groups": [
    {"name": "主节点", "proxies": ["node-12", "DIRECT"]}
  ],
  "rules": ["DOMAIN,x.com,node-12", "MATCH,主节点"]
}''';

    final String shown = NodeLabels.annotateRuntimeConfig(raw);
    expect(shown, contains('"node-12（香港 01）"'));
    expect(shown, contains('"node-1（备用）"'));
    expect(shown, contains('DOMAIN,x.com,node-12（香港 01）'));
    expect(shown, contains('"DIRECT"'));
    expect(shown, contains('"MATCH,主节点"'));
    expect(shown, isNot(contains('node-12（备用）')));

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

    NodeLabels.configure(r'/[\p{L}\p{N}]+/u');
  });

  test('随包素材按文件名即标识的约定取得到', () async {
    final AssetManifest manifest = await AssetManifest.loadFromAssetBundle(
      rootBundle,
    );
    final List<String> assets = manifest
        .listAssets()
        .where((String key) => key.startsWith('assets/'))
        .toList(growable: false);

    // 旗帜来自面板目录，同步过就一定有（策略组图标不随包，由面板下发地址后运行期缓存）
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
