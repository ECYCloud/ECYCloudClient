import 'package:flutter/material.dart';

import '../../data/store/settings_store.dart';
import '../../domain/platform/platform_service.dart';
import '../../state/connection_controller.dart';
import '../app_scope.dart';
import '../widgets/option_dropdown.dart';
import '../widgets/search_field.dart';

class PerAppProxyPage extends StatefulWidget {
  const PerAppProxyPage({super.key});

  static const Map<PerAppProxyMode, String> modes =
      <PerAppProxyMode, String>{
        PerAppProxyMode.off: '全部应用',
        PerAppProxyMode.include: '仅所选应用',
        PerAppProxyMode.exclude: '所选应用除外',
      };

  @override
  State<PerAppProxyPage> createState() => _PerAppProxyPageState();
}

class _PerAppProxyPageState extends State<PerAppProxyPage> {
  List<InstalledApp>? _apps;
  String? _error;
  String _keyword = '';
  bool _showSystem = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_apps == null && _error == null) {
      _load();
    }
  }

  Future<void> _load() async {
    final PlatformService platform = AppScope.of(context).platform;
    try {
      final List<InstalledApp> apps = await platform.installedApps();
      apps.sort(
        (InstalledApp a, InstalledApp b) =>
            a.label.toLowerCase().compareTo(b.label.toLowerCase()),
      );
      if (mounted) {
        setState(() => _apps = apps);
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = '读取应用列表失败：$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ConnectionController connection = AppScope.of(context).connection;

    return Scaffold(
      appBar: AppBar(title: const Text('分应用代理')),
      body: ListenableBuilder(
        listenable: connection,
        builder: (BuildContext context, _) {
          final AppSettings settings = connection.settings;
          final Set<String> selected = settings.perAppPackages.toSet();

          return Column(
            children: <Widget>[
              ListTile(
                title: const Text('生效范围'),
                subtitle: const Text('改动在下次连接或重连后生效'),
                trailing: OptionDropdown<PerAppProxyMode>(
                  value: settings.perAppMode,
                  options: PerAppProxyPage.modes,
                  width: 140,
                  onChanged: (PerAppProxyMode mode) => connection
                      .updateSettings(settings.copyWith(perAppMode: mode)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: SearchField(
                        hintText: '搜索应用',
                        width: double.infinity,
                        onChanged: (String value) =>
                            setState(() => _keyword = value.toLowerCase()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: const Text('系统应用'),
                      selected: _showSystem,
                      onSelected: (bool value) =>
                          setState(() => _showSystem = value),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _body(connection, settings, selected)),
            ],
          );
        },
      ),
    );
  }

  Widget _body(
    ConnectionController connection,
    AppSettings settings,
    Set<String> selected,
  ) {
    final String? error = _error;
    if (error != null) {
      return Center(child: Text(error));
    }

    final List<InstalledApp>? apps = _apps;
    if (apps == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final List<InstalledApp> visible = <InstalledApp>[
      for (final InstalledApp app in apps)
        if ((_showSystem || !app.system) &&
            (_keyword.isEmpty ||
                app.label.toLowerCase().contains(_keyword) ||
                app.packageName.toLowerCase().contains(_keyword)))
          app,
    ];

    if (visible.isEmpty) {
      return const Center(child: Text('没有匹配的应用'));
    }

    final bool enabled = settings.perAppMode != PerAppProxyMode.off;

    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (BuildContext context, int index) {
        final InstalledApp app = visible[index];
        return CheckboxListTile(
          value: selected.contains(app.packageName),
          title: Text(app.label),
          subtitle: Text(app.packageName),
          onChanged: enabled
              ? (bool? value) {
                  final Set<String> next = <String>{...selected};
                  if (value == true) {
                    next.add(app.packageName);
                  } else {
                    next.remove(app.packageName);
                  }
                  connection.updateSettings(
                    settings.copyWith(perAppPackages: next.toList()..sort()),
                  );
                }
              : null,
        );
      },
    );
  }
}
