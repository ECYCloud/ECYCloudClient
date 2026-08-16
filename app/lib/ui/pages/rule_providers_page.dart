import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/app_paths.dart';
import '../../state/connection_controller.dart';
import '../app_scope.dart';
import 'text_viewer_page.dart';
import '../../l10n/l10n.dart';

/// 列出已落盘的 rule-providers，点进只读查看。
class RuleProvidersPage extends StatelessWidget {
  const RuleProvidersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ConnectionController connection = AppScope.of(context).connection;
    final List<RuleProviderRef> items = connection.ruleProviderRefs();
    final ThemeData theme = Theme.of(context);
    final String rulesDir =
        '${AppPaths.kernelRunDir}${Platform.pathSeparator}ECYCloud-Rules';

    return Scaffold(
      appBar: AppBar(title: Text(L10n.t('分流规则'))),
      body: items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  L10n.t('暂无分流规则。连接一次后，规则会下载到运行目录。'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: items.length + 1,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (BuildContext context, int index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Text(
                      rulesDir,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                final RuleProviderRef item = items[index - 1];
                return ListTile(
                  title: Text(item.name),
                  subtitle: Text(item.relativePath),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TextViewerPage(
                        title: item.name,
                        subtitle: item.relativePath,
                        load: () => connection.readRunFile(item.relativePath),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
