import 'package:flutter/material.dart';
import 'package:flutter/services.dart';


/// 只读文本查看（运行配置 / 分流规则）。不提供编辑。
class TextViewerPage extends StatefulWidget {
  const TextViewerPage({
    required this.title,
    required this.load,
    this.subtitle,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Future<String> Function() load;

  @override
  State<TextViewerPage> createState() => _TextViewerPageState();
}

class _TextViewerPageState extends State<TextViewerPage> {
  late final Future<String> _future = widget.load();
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: <Widget>[
          FutureBuilder<String>(
            future: _future,
            builder: (BuildContext context, AsyncSnapshot<String> snap) {
              final String? text = snap.data;
              if (text == null || text.isEmpty) {
                return const SizedBox.shrink();
              }
              return IconButton(
                tooltip: '复制全部',
                icon: const Icon(Icons.copy_all_outlined),
                onPressed: () => Clipboard.setData(ClipboardData(text: text)),
              );
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.subtitle != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                widget.subtitle!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Expanded(
            child: FutureBuilder<String>(
              future: _future,
              builder: (BuildContext context, AsyncSnapshot<String> snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        '${snap.error}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  );
                }
                final String text = snap.data ?? '';
                if (text.isEmpty) {
                  return Center(
                    child: Text('文件为空或不存在', style: theme.textTheme.bodyLarge),
                  );
                }
                // Scrollbar 与 ScrollView 必须共用同一 controller，否则桌面端拇指无法拖拽
                return Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: SelectableText(
                      text,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'Consolas',
                        fontFamilyFallback: const <String>[
                          'Menlo',
                          'monospace',
                        ],
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
