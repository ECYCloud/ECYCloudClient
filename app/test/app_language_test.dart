import 'dart:ui';

import 'package:ecycloud_client/l10n/app_language.dart';
import 'package:ecycloud_client/l10n/l10n.dart';
import 'package:ecycloud_client/data/store/settings_store.dart';
import 'package:ecycloud_client/data/api/api_exception.dart';
import 'package:ecycloud_client/domain/kernel/clash_api_client.dart';
import 'package:ecycloud_client/domain/kernel/kernel_controller.dart';
import 'package:ecycloud_client/domain/kernel/node_speed_tester.dart';
import 'package:ecycloud_client/domain/update/github_release.dart';
import 'package:ecycloud_client/platform/service/service_transport.dart';
import 'package:ecycloud_client/platform/windows/service_control.dart';
import 'package:ecycloud_client/platform/windows/service_pipe.dart';
import 'package:ecycloud_client/l10n/translations.dart';
import 'package:flutter_test/flutter_test.dart';

class _LanguageSettingsStore implements SettingsStore {
  AppSettings settings = const AppSettings.defaults();
  int saves = 0;

  @override
  bool get hasPersistedSettings => true;

  @override
  AppSettings load() => settings;

  @override
  void save(AppSettings value) {
    settings = value;
    saves++;
  }
}

void main() {
  test('异常显示翻译静态和动态提示，原始信息、参数与错误码不变', () {
    addTearDown(() => L10n.current = AppLanguage.zhCN);
    final ApiException api = ApiException('上传失败', statusCode: 413);
    final ClashApiException clash = ClashApiException('节点 自定义中文节点 不可用');
    final ServiceException service = ServiceException('后台服务未返回任何内容');
    final GithubReleaseException update = GithubReleaseException(
      'GitHub 返回 HTTP 429',
    );
    final KernelException kernel = KernelException('内核启动失败：fixture');
    final NodeSpeedTestException speed = NodeSpeedTestException('测速超时');
    L10n.current = AppLanguage.en;
    expect('$api', 'Upload failed');
    expect(api.message, '上传失败');
    expect(api.statusCode, 413);
    expect('$clash', 'Node 自定义中文节点 is unavailable.');
    expect('$service', 'The background service returned no content.');
    expect('$update', 'GitHub returned HTTP 429.');
    expect('$kernel', 'Could not start the kernel: fixture');
    expect('$speed', 'Speed test timed out.');
    final nativeErrors = [
      '缺少 enabled',
      '缺少 path',
      '读取系统界面字体失败',
      '写入开机自启项失败',
      '没有可用的内核配置',
      '节点文件不能为空',
      '运行目录类型不可信',
      '节点文件类型或链接数不可信',
      '不能读取目录',
    ];
    expect(
      [
        for (final source in nativeErrors)
          if (RegExp(
            r'\p{Script=Han}',
            unicode: true,
          ).hasMatch('${KernelException(source)}'))
            source,
      ],
      isEmpty,
      reason: '原生平台异常经过实际显示出口后不应残留中文',
    );
    const ServiceProbe probe = ServiceProbe(
      WindowsServiceState.unknown,
      detail: '无法连接服务控制管理器（Win32 错误 5）',
    );
    expect(
      ServicePipe.describe(probe),
      'Background service status: Unknown state. Unable to connect: Could not connect to the Service Control Manager (Win32 error 5).',
    );
    expect(probe.detail, '无法连接服务控制管理器（Win32 错误 5）');
    expect(L10n.message('未知测试内容'), '未知测试内容');
    L10n.current = AppLanguage.zhTW;
    expect('$api', '上傳失敗');
    expect('$clash', '節點 自定义中文节点 無法使用');
    expect('$update', 'GitHub 回傳 HTTP 429');
    L10n.current = AppLanguage.zhCN;
    expect('$clash', clash.message);
  });

  test('两套客户端词典一致，所有参数均保留', () {
    final en = kTranslations[AppLanguage.en]!;
    final tw = kTranslations[AppLanguage.zhTW]!;
    expect(en.keys.toSet(), tw.keys.toSet());
    for (final key in en.keys) {
      Set<String?> tokens(String text) =>
          RegExp(r'\{\d+\}').allMatches(text).map((match) => match[0]).toSet();
      expect(tokens(en[key]!), tokens(key), reason: key);
      expect(tokens(tw[key]!), tokens(key), reason: key);
    }
  });

  test('已拼接的系统提示逐项匹配模板并保留中文参数', () {
    addTearDown(() => L10n.current = AppLanguage.zhCN);
    for (final language in <AppLanguage>[AppLanguage.en, AppLanguage.zhTW]) {
      L10n.current = language;
      for (final entry in kTranslations[language]!.entries) {
        if (!RegExp(r'\{\d+\}').hasMatch(entry.key)) continue;
        String fill(String text) => text.replaceAllMapped(
          RegExp(r'\{(\d+)\}'),
          (match) => 'fixture_${match[1]}_中文',
        );
        expect(
          L10n.message(fill(entry.key)),
          fill(entry.value),
          reason: '${language.name}: ${entry.key}',
        );
      }
    }
  });

  test('设备语言：保留简中、繁中与英文，其余默认英文', () {
    expect(AppLanguage.fromDevice(const Locale('en', 'US')), AppLanguage.en);
    expect(AppLanguage.fromDevice(const Locale('zh', 'TW')), AppLanguage.zhTW);
    expect(AppLanguage.fromDevice(const Locale('zh', 'HK')), AppLanguage.zhTW);
    expect(
      AppLanguage.fromDevice(
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      ),
      AppLanguage.zhTW,
    );
    expect(AppLanguage.fromDevice(const Locale('zh', 'CN')), AppLanguage.zhCN);
    for (final locale in <Locale>[
      const Locale('ja', 'JP'),
      const Locale('fr', 'FR'),
      const Locale('ko', 'KR'),
      const Locale('ru', 'RU'),
      const Locale('und'),
    ]) {
      expect(AppLanguage.fromDevice(locale), AppLanguage.en);
      expect(AppLanguage.resolve(stored: '', device: locale), AppLanguage.en);
      expect(
        AppLanguage.resolve(stored: 'invalid', device: locale),
        AppLanguage.en,
      );
      for (final language in AppLanguage.values) {
        expect(
          AppLanguage.resolve(stored: language.code, device: locale),
          language,
        );
      }
    }
  });

  test('已保存的语言优先于设备语言', () {
    expect(
      AppLanguage.resolve(stored: 'en', device: const Locale('zh', 'CN')),
      AppLanguage.en,
    );
    expect(AppLanguage.tryParse('zh_TW'), AppLanguage.zhTW);
    expect(AppLanguage.tryParse('en-US'), AppLanguage.en);
    expect(AppLanguage.en.contentLanguage, 'en-US');
    expect(AppLanguage.en.flutterLocale, const Locale('en', 'US'));
    expect(AppLanguage.tryParse(''), isNull);
  });

  test('旧英文设置转换为 en-US，保留其他设置且只保存一次', () {
    final _LanguageSettingsStore store = _LanguageSettingsStore();
    final AppSettings original = const AppSettings.defaults().copyWith(
      locale: 'en',
      mixedPort: 20503,
    );
    final AppSettings normalized = AppLanguage.seed(store, original);
    expect(normalized.locale, 'en-US');
    expect(normalized.mixedPort, original.mixedPort);
    expect(original.affectsKernel(normalized), isFalse);
    expect(store.load(), same(normalized));
    expect(AppLanguage.seed(store, normalized), same(normalized));
    expect(store.saves, 1);
  });

  test('旧设置没有语言时跟随设备，已保存的语言保持优先', () {
    final store = _LanguageSettingsStore();
    final original = const AppSettings.defaults().copyWith(mixedPort: 20503);
    final normalized = AppLanguage.seed(store, original);
    expect(
      normalized.locale,
      AppLanguage.fromDevice(PlatformDispatcher.instance.locale).code,
    );
    expect(normalized.mixedPort, original.mixedPort);
    expect(original.affectsKernel(normalized), isFalse);
    expect(store.load(), same(normalized));
    expect(AppLanguage.seed(store, normalized), same(normalized));
    expect(store.saves, 1);
    for (final language in AppLanguage.values) {
      final selected = original.copyWith(locale: language.code);
      expect(AppLanguage.seed(store, selected), same(selected));
    }
    expect(store.saves, 1);
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
