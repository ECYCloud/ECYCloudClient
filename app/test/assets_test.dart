import 'package:ecycloud_client/ui/node_labels.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('地区按面板下发的取词正则 + 随包映射表认出来', () async {
    await NodeLabels.load();
    // 正则由面板 /config/sing-box 下发，测试里直接给面板设置项的原文
    NodeLabels.configure(r'/[\p{L}\p{N}]+/u');

    expect(NodeLabels.region('香港 Ⅱ · D1'), 'hk');
    expect(NodeLabels.region('us 美国 X · A1 [VLESS]'), 'us');
    // 名字里直接写 ISO 代码时靠自动补全的自映射命中
    expect(NodeLabels.region('FR-Paris-1'), 'fr');
    expect(NodeLabels.region('巴哈姆特专线'), isNull);
  });

  test('名字自带国旗 emoji 时直接反推代码，不查表', () async {
    await NodeLabels.load();

    expect(NodeLabels.region('🇭🇰HK01'), 'hk');
    // 取词正则认不出「Japan」，但 emoji 能认
    expect(NodeLabels.region('🇯🇵 Japan 01'), 'jp');
    expect(NodeLabels.region('Japan 01'), isNull);
  });

  test('展示名去掉国旗 emoji，地区只由旗帜图标表达', () {
    expect(NodeLabels.displayName('🇹🇼 台湾 Ⅱ · A1 [CF]'), '台湾 Ⅱ · A1 [CF]');
    expect(NodeLabels.displayName('🇺🇸美国 Ⅲ · B2'), '美国 Ⅲ · B2');
    expect(NodeLabels.displayName('香港 Ⅱ · D1'), '香港 Ⅱ · D1');
    // 整个名字只有旗帜时不能剥成空串
    expect(NodeLabels.displayName('🇯🇵'), '🇯🇵');
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

    // 中文与含空格的资源名最容易在资源表里出问题，逐个真读一遍
    for (final String asset in assets) {
      final ByteData data = await rootBundle.load(asset);
      expect(data.lengthInBytes, greaterThan(0), reason: asset);
    }
  });
}
