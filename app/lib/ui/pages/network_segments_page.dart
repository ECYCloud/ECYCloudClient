import 'package:flutter/material.dart';

import '../../data/store/settings_store.dart';
import '../../domain/config/network_bypass.dart';
import '../../l10n/l10n.dart';
import '../../state/connection_controller.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/tag_chip.dart';

Future<void> openSystemProxyBypass(BuildContext context) {
  final AppScope scope = AppScope.of(context);
  final ConnectionController connection = scope.connection;
  final AppSettings settings = connection.settings;
  final bool windows = scope.platform.platformId == 'windows';
  return editNetworkSegments(
    context,
    title: L10n.t('系统代理绕过'),
    helperText: windows
        ? L10n.t('追加到默认列表，支持通配，例如 192.168.56.* 或 example.com')
        : L10n.t('追加到默认列表，例如 192.168.56.0/24 或 *.local'),
    hintText: windows ? '192.168.56.*' : '192.168.56.0/24',
    items: settings.systemProxyBypass,
    lockedItems: defaultSystemProxyBypass(scope.platform.platformId),
    lockedLabel: L10n.t('默认绕过'),
    onSave: (List<String> value) => connection.updateSettings(
      connection.settings.copyWith(systemProxyBypass: value),
    ),
  );
}

Future<void> openTunExcludeAddresses(BuildContext context) {
  final ConnectionController connection = AppScope.of(context).connection;
  return editNetworkSegments(
    context,
    title: L10n.t('排除自定义网段'),
    helperText: L10n.t(
      '仅支持 IPv4/IPv6 CIDR，例如 192.168.56.0/24 或 fd00::/8；局域网与回环已默认排除',
    ),
    hintText: '192.168.56.0/24',
    items: connection.settings.tunExcludeAddresses,
    validate: (String value) =>
        isIpCidr(value) ? null : L10n.t('仅支持 IPv4/IPv6 CIDR'),
    onSave: (List<String> value) => connection.updateSettings(
      connection.settings.copyWith(tunExcludeAddresses: value),
    ),
  );
}

Future<void> editNetworkSegments(
  BuildContext context, {
  required String title,
  required String helperText,
  required String hintText,
  required List<String> items,
  required Future<void> Function(List<String> value) onSave,
  List<String> lockedItems = const <String>[],
  String? lockedLabel,
  String? Function(String value)? validate,
}) async {
  final List<String>? next = await Navigator.of(context).push<List<String>>(
    MaterialPageRoute<List<String>>(
      builder: (BuildContext context) => NetworkSegmentsPage(
        title: title,
        helperText: helperText,
        hintText: hintText,
        items: items,
        lockedItems: lockedItems,
        lockedLabel: lockedLabel,
        validate: validate,
      ),
    ),
  );
  if (next == null) {
    return;
  }
  await onSave(next);
}

class NetworkSegmentsPage extends StatefulWidget {
  const NetworkSegmentsPage({
    super.key,
    required this.title,
    required this.helperText,
    required this.hintText,
    required this.items,
    required this.lockedItems,
    required this.lockedLabel,
    required this.validate,
  });

  final String title;
  final String helperText;
  final String hintText;
  final List<String> items;
  final List<String> lockedItems;
  final String? lockedLabel;
  final String? Function(String value)? validate;

  @override
  State<NetworkSegmentsPage> createState() => _NetworkSegmentsPageState();
}

class _NetworkSegmentsPageState extends State<NetworkSegmentsPage> {
  late final List<String> _items = List<String>.of(widget.items);
  final TextEditingController _input = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _add() {
    final List<String> candidates = splitNetworkSegments(_input.text);
    if (candidates.isEmpty) {
      setState(() => _error = L10n.t('请输入网段'));
      return;
    }

    String? error;
    for (final String item in candidates) {
      error = widget.validate?.call(item);
      if (error != null) {
        break;
      }
      if (_items.contains(item) || widget.lockedItems.contains(item)) {
        error = L10n.t('已存在');
        break;
      }
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }

    setState(() {
      _items.addAll(candidates);
      _error = null;
    });
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String? lockedLabel = widget.lockedLabel;
    final TextStyle? helperStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(context).pop(List<String>.of(_items)),
            child: Text(L10n.t('保存')),
          ),
        ],
      ),
      body: ListView(
        padding: AppTheme.pageScrollPadding,
        children: <Widget>[
          if (lockedLabel != null && widget.lockedItems.isNotEmpty) ...<Widget>[
            Text(lockedLabel, style: helperStyle),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final String item in widget.lockedItems)
                  TagChip(label: item),
              ],
            ),
            const SizedBox(height: 14),
            Text(L10n.t('自定义'), style: helperStyle),
            const SizedBox(height: 8),
          ],
          if (_items.isEmpty)
            Text(L10n.t('尚未添加'), style: helperStyle)
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final String item in _items)
                  InputChip(
                    label: Text(item),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onDeleted: () => setState(() => _items.remove(item)),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _input,
                  decoration: InputDecoration(hintText: widget.hintText),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _add, child: Text(L10n.t('添加'))),
            ],
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
          const SizedBox(height: 8),
          Text(widget.helperText, style: helperStyle),
        ],
      ),
    );
  }
}
