import 'dart:ui';

import 'package:ecycloud_client/l10n/app_language.dart';
import 'package:ecycloud_client/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('设备语言：英文与繁中落到对应项，其余默认简中', () {
    expect(AppLanguage.fromDevice(const Locale('en', 'US')), AppLanguage.en);
    expect(AppLanguage.fromDevice(const Locale('zh', 'TW')), AppLanguage.zhTW);
    expect(AppLanguage.fromDevice(const Locale('zh', 'HK')), AppLanguage.zhTW);
    expect(
      AppLanguage.fromDevice(const Locale.fromSubtags(
        languageCode: 'zh',
        scriptCode: 'Hant',
      )),
      AppLanguage.zhTW,
    );
    expect(AppLanguage.fromDevice(const Locale('zh', 'CN')), AppLanguage.zhCN);
    expect(AppLanguage.fromDevice(const Locale('ja', 'JP')), AppLanguage.zhCN);
  });

  test('已保存的语言优先于设备语言', () {
    expect(
      AppLanguage.resolve(
        stored: 'en',
        device: const Locale('zh', 'CN'),
      ),
      AppLanguage.en,
    );
    expect(AppLanguage.tryParse('zh_TW'), AppLanguage.zhTW);
    expect(AppLanguage.tryParse(''), isNull);
  });

  test('L10n 按当前语言替换占位符，缺词回落到简中原文', () {
    L10n.current = AppLanguage.en;
    expect(L10n.t('设置'), 'Settings');
    expect(L10n.t('账户信息'), 'Account');
    expect(L10n.t('更新失败：{0}', <Object>['timeout']), 'Update failed: timeout');
    expect(L10n.t('不会出现的词'), '不会出现的词');

    L10n.current = AppLanguage.zhTW;
    expect(L10n.t('设置'), '設定');

    L10n.current = AppLanguage.zhCN;
    expect(L10n.t('设置'), '设置');
  });
}
