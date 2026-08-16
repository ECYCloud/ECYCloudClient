import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/app_paths.dart';
import '../../core/logger.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/panel_api_client.dart';
import '../../data/models/ticket.dart';
import '../app_scope.dart';
import '../theme.dart';
import '../widgets/list_toolbar.dart';
import '../widgets/page_header.dart';
import '../widgets/refresh_button.dart';
import '../widgets/section_card.dart';
import '../widgets/rich_html_view.dart';
import '../widgets/tag_chip.dart';
import '../widgets/multiline_content_field.dart';
import '../../l10n/l10n.dart';

class TicketsPage extends StatefulWidget {
  const TicketsPage({super.key, this.showBackButton = false});

  final bool showBackButton;

  @override
  State<TicketsPage> createState() => _TicketsPageState();
}

class _TicketsPageState extends State<TicketsPage> {
  List<TicketSummary> _tickets = const <TicketSummary>[];
  int _page = 1;
  int _lastPage = 1;
  int _total = 0;
  int _perPage = 10;
  String _search = '';
  bool _banned = false;
  String? _error;
  bool _busy = false;
  bool _started = false;
  Timer? _searchDebounce;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (api == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final TicketListPage result = await api.fetchTickets(
        page: _page,
        length: _perPage,
        search: _search,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _tickets = result.tickets;
        _page = result.currentPage;
        _lastPage = result.lastPage;
        _total = result.total;
        _perPage = result.perPage > 0 ? result.perPage : _perPage;
        _banned = result.banned;
        _busy = false;
      });
    } on Object catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e is ApiException ? e.message : L10n.t('加载失败：{0}', <Object>[e]);
        _busy = false;
      });
    }
  }

  void _onSearch(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _search = value.trim();
      _page = 1;
      unawaited(_load());
    });
  }

  Future<void> _create() async {
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (api == null) {
      return;
    }
    final _TicketEditorResult? draft = await showDialog<_TicketEditorResult>(
      context: context,
      builder: (BuildContext context) => _TicketEditorDialog(
        titleLabel: L10n.t('创建工单'),
        requireTitle: true,
        api: api,
      ),
    );
    if (draft == null) {
      return;
    }
    try {
      final int id = await api.createTicket(
        title: draft.title,
        content: draft.content,
      );
      if (!mounted) {
        return;
      }
      await _load();
      if (!mounted) {
        return;
      }
      await _openDetail(id);
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _openDetail(int id) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => _TicketDetailPage(ticketId: id),
      ),
    );
    if (mounted) {
      await _load();
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: <Widget>[
          PageHeader(
            title: L10n.t('工单'),
            showBackButton: widget.showBackButton,
            showUserAvatar: true,
            actions: <Widget>[
              FilledButton.icon(
                onPressed: _busy || _banned ? null : _create,
                icon: const Icon(Icons.add, size: 16),
                label: Text(L10n.t('创建工单')),
              ),
              const SizedBox(width: PageHeader.actionGap),
              RefreshButton(tooltip: L10n.t('刷新工单'), onRefresh: _load),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
            child: SizedBox(
              width: double.infinity,
              child: SectionCard(
                child: Text(
                  L10n.t('如需与我们沟通，请点击上方创建工单按钮。'),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          ),
          ListToolbar(
            currentPage: _page,
            lastPage: _lastPage,
            total: _total,
            perPage: _perPage,
            searchHint: L10n.t('标题 / 工单号'),
            onSearchChanged: _onSearch,
            onPerPageChanged: (int value) {
              _perPage = value;
              _page = 1;
              unawaited(_load());
            },
            onPageChanged: (int page) {
              _page = page;
              unawaited(_load());
            },
          ),
          if (_banned)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Text(
                L10n.t('您已被禁止发起或回复工单'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _busy && _tickets.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const <Widget>[
                        SizedBox(height: 120),
                        Center(child: CircularProgressIndicator()),
                      ],
                    )
                  : _error != null && _tickets.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(24),
                      children: <Widget>[
                        const SizedBox(height: 80),
                        Icon(
                          Icons.error_outline,
                          size: 40,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(height: 12),
                        Text(_error!, textAlign: TextAlign.center),
                      ],
                    )
                  : _tickets.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: <Widget>[
                        SizedBox(height: 120),
                        Center(child: Text(L10n.t('暂无工单'))),
                      ],
                    )
                  : ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(14),
                      itemCount: _tickets.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (BuildContext context, int index) {
                        final TicketSummary ticket = _tickets[index];
                        return Card(
                          child: ListTile(
                            title: Text(ticket.title),
                            subtitle: Text('#${ticket.id} · ${ticket.datetime}'),
                            trailing: TagChip(label: ticket.statusText),
                            onTap: () => _openDetail(ticket.id),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TicketDetailPage extends StatefulWidget {
  const _TicketDetailPage({required this.ticketId});

  final int ticketId;

  @override
  State<_TicketDetailPage> createState() => _TicketDetailPageState();
}

class _TicketDetailPageState extends State<_TicketDetailPage> {
  TicketDetail? _detail;
  String? _error;
  bool _busy = true;
  int _msgPage = 1;
  int _msgPerPage = 10;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (api == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final TicketDetail detail = await api.fetchTicket(widget.ticketId);
      if (!mounted) {
        return;
      }
      setState(() {
        _detail = detail;
        _msgPage = 1;
        _busy = false;
      });
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  Future<void> _reply() async {
    final TicketDetail? detail = _detail;
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (detail == null || api == null || detail.banned) {
      return;
    }
    final _TicketEditorResult? draft = await showDialog<_TicketEditorResult>(
      context: context,
      builder: (BuildContext context) => _TicketEditorDialog(
        titleLabel: L10n.t('回复工单'),
        requireTitle: false,
        api: api,
      ),
    );
    if (draft == null) {
      return;
    }
    try {
      await api.replyTicket(id: detail.id, content: draft.content);
      if (!mounted) {
        return;
      }
      await _load();
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _closeTicket() async {
    final TicketDetail? detail = _detail;
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (detail == null || api == null || detail.banned || detail.status == 0) {
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(L10n.t('关闭工单')),
        content: Text(L10n.t('确定关闭此工单？')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L10n.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            child: Text(L10n.t('关闭工单')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    try {
      await api.closeTicket(detail.id);
      if (!mounted) {
        return;
      }
      await _load();
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final TicketDetail? detail = _detail;
    final ThemeData theme = Theme.of(context);
    final List<TicketMessage> allMessages =
        detail?.messages ?? const <TicketMessage>[];
    final int msgLastPage = allMessages.isEmpty
        ? 1
        : ((allMessages.length + _msgPerPage - 1) / _msgPerPage).ceil();
    final int safeMsgPage = _msgPage.clamp(1, msgLastPage);
    final int msgStart = (safeMsgPage - 1) * _msgPerPage;
    final List<TicketMessage> pageMessages = allMessages.isEmpty
        ? const <TicketMessage>[]
        : allMessages.sublist(
            msgStart,
            msgStart + _msgPerPage > allMessages.length
                ? allMessages.length
                : msgStart + _msgPerPage,
          );

    return Scaffold(
      body: Column(
        children: <Widget>[
          SafeArea(
            bottom: false,
            child: PageHeader(
              title: detail?.title ?? L10n.t('工单详情'),
              showBackButton: true,
              showUserAvatar: true,
              actions: <Widget>[
                if (detail != null && !detail.banned) ...<Widget>[
                  if (detail.status != 0) ...<Widget>[
                    FilledButton(
                      onPressed: _closeTicket,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.danger,
                      ),
                      child: Text(L10n.t('关闭工单')),
                    ),
                    const SizedBox(width: PageHeader.actionGap),
                  ],
                  FilledButton.icon(
                    onPressed: _reply,
                    icon: const Icon(Icons.reply, size: 16),
                    label: Text(L10n.t('回复工单')),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: _busy && detail == null
                ? const Center(child: CircularProgressIndicator())
                : _error != null && detail == null
                ? Center(child: Text(_error!))
                : detail == null
                ? Center(child: Text(L10n.t('工单不存在')))
                : Column(
                    children: <Widget>[
                      ListToolbar(
                  currentPage: safeMsgPage,
                  lastPage: msgLastPage,
                  total: allMessages.length,
                  perPage: _msgPerPage,
                  showSearch: false,
                  onSearchChanged: (_) {},
                  onPerPageChanged: (int value) {
                    setState(() {
                      _msgPerPage = value;
                      _msgPage = 1;
                    });
                  },
                  onPageChanged: (int page) {
                    setState(() => _msgPage = page);
                  },
                ),
                Expanded(
                  child: Builder(
                    builder: (BuildContext context) {
                      final List<String> imageAlbum = collectHtmlImageSrcs(
                        detail.messages.map((TicketMessage m) => m.content),
                      );
                      return ListView(
                        padding: const EdgeInsets.all(14),
                        children: <Widget>[
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 6,
                            children: <Widget>[
                              TagChip(label: detail.statusText),
                              Text(
                                L10n.t('创建 {0}', <Object>[detail.datetime]),
                                style: theme.textTheme.bodySmall,
                              ),
                              Text(
                                L10n.t('共 {0} 条消息', <Object>[detail.messageCount]),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                          if (detail.banned) ...<Widget>[
                            const SizedBox(height: 8),
                            Text(
                              L10n.t('您已被禁止回复工单'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          if (pageMessages.isEmpty)
                            Padding(
                              padding: EdgeInsets.only(top: 40),
                              child: Center(child: Text(L10n.t('暂无消息'))),
                            )
                          else
                            for (final TicketMessage message
                                in pageMessages) ...<Widget>[
                              Card(
                                color: message.isAdmin
                                    ? theme.colorScheme.surfaceContainerHighest
                                    : null,
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: <Widget>[
                                          Flexible(
                                            child: Text(
                                              L10n.t(message.userName),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.titleSmall
                                                  ?.copyWith(
                                                color: message.isAdmin
                                                    ? AppTheme.warning
                                                    : theme.colorScheme.primary,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Flexible(
                                            child: Text(
                                              message.datetime,
                                              textAlign: TextAlign.right,
                                              style: theme.textTheme.bodySmall,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      RichHtmlView(
                                        message.content,
                                        imageAlbum: imageAlbum,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TicketAttachment {
  const _TicketAttachment({
    required this.url,
    required this.name,
    required this.kind,
  });

  final String url;
  final String name;
  final String kind;
}

class _TicketEditorResult {
  const _TicketEditorResult({
    required this.title,
    required this.content,
  });

  final String title;
  final String content;
}

class _TicketEditorDialog extends StatefulWidget {
  const _TicketEditorDialog({
    required this.titleLabel,
    required this.requireTitle,
    required this.api,
  });

  final String titleLabel;
  final bool requireTitle;
  final PanelApiClient api;

  @override
  State<_TicketEditorDialog> createState() => _TicketEditorDialogState();
}

class _TicketEditorDialogState extends State<_TicketEditorDialog> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _content = TextEditingController();
  final List<_TicketAttachment> _attachments = <_TicketAttachment>[];
  bool _uploading = false;

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  String _buildHtml() {
    final String text = _content.text.trim();
    final StringBuffer buf = StringBuffer();
    if (text.isNotEmpty) {
      buf.write(
        const HtmlEscape().convert(text).replaceAll('\n', '<br>'),
      );
    }
    for (final _TicketAttachment item in _attachments) {
      if (item.kind == 'image') {
        buf.write('<p><img src="${item.url}" alt="${_attr(item.name)}"></p>');
      } else if (item.kind == 'video') {
        buf.write('<p><video src="${item.url}" controls></video></p>');
      } else {
        buf.write(
          '<p><a href="${item.url}">${const HtmlEscape().convert(item.name)}</a></p>',
        );
      }
    }
    return buf.toString();
  }

  String _attr(String value) =>
      const HtmlEscape(HtmlEscapeMode.attribute).convert(value);

  Future<void> _pickMedia({required bool video}) async {
    final FilePickerResult? result = await FilePicker.pickFiles(
      type: video ? FileType.video : FileType.image,
      allowMultiple: true,
      withData: false,
    );
    if (result == null || result.files.isEmpty) {
      return;
    }
    await _uploadPaths(
      result.files
          .map((PlatformFile f) => f.path)
          .whereType<String>()
          .toList(),
    );
  }

  Future<void> _uploadRuntimeLog() async {
    await Logger.instance.flush();
    final Directory dir = AppPaths.logs;
    if (!dir.existsSync()) {
      _toast(L10n.t('暂无运行日志'));
      return;
    }
    final List<File> logs = dir
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.log'))
        .toList();
    if (logs.isEmpty) {
      _toast(L10n.t('暂无运行日志'));
      return;
    }
    logs.sort(
      (File a, File b) =>
          b.lastModifiedSync().compareTo(a.lastModifiedSync()),
    );
    await _uploadPaths(<String>[logs.first.path]);
  }

  Future<void> _uploadPaths(List<String> paths) async {
    if (paths.isEmpty) {
      return;
    }
    setState(() => _uploading = true);
    try {
      for (final String path in paths) {
        final TicketUploadResult uploaded =
            await widget.api.uploadTicketAttachment(path);
        if (!mounted) {
          return;
        }
        setState(() {
          _attachments.add(
            _TicketAttachment(
              url: uploaded.url,
              name: uploaded.originalName.isEmpty
                  ? path.split(Platform.pathSeparator).last
                  : uploaded.originalName,
              kind: uploaded.kind,
            ),
          );
        });
      }
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) {
        setState(() => _uploading = false);
      }
    }
  }

  void _toast(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  void _submit() {
    final String title = _title.text.trim();
    final String html = _buildHtml();
    if (widget.requireTitle && title.isEmpty) {
      return;
    }
    if (html.trim().isEmpty) {
      return;
    }
    Navigator.of(context).pop(
      _TicketEditorResult(title: title, content: html),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.titleLabel),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.requireTitle) ...<Widget>[
              TextField(
                controller: _title,
                decoration: InputDecoration(labelText: L10n.t('标题')),
              ),
              const SizedBox(height: 12),
            ],
            MultilineContentField(
              controller: _content,
              labelText: L10n.t('内容'),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _uploading ? null : () => _pickMedia(video: false),
                  icon: const Icon(Icons.image_outlined, size: 16),
                  label: Text(L10n.t('图片')),
                ),
                OutlinedButton.icon(
                  onPressed: _uploading ? null : () => _pickMedia(video: true),
                  icon: const Icon(Icons.videocam_outlined, size: 16),
                  label: Text(L10n.t('视频')),
                ),
                OutlinedButton.icon(
                  onPressed: _uploading ? null : _uploadRuntimeLog,
                  icon: const Icon(Icons.bug_report_outlined, size: 16),
                  label: Text(L10n.t('运行日志')),
                ),
                if (_uploading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (_attachments.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (int i = 0; i < _attachments.length; i++)
                    InputChip(
                      label: Text(_attachments[i].name),
                      avatar: Icon(
                        switch (_attachments[i].kind) {
                          'image' => Icons.image_outlined,
                          'video' => Icons.videocam_outlined,
                          _ => Icons.attach_file,
                        },
                        size: 16,
                      ),
                      onDeleted: _uploading
                          ? null
                          : () => setState(() => _attachments.removeAt(i)),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _uploading ? null : () => Navigator.of(context).pop(),
          child: Text(L10n.t('取消')),
        ),
        FilledButton(
          onPressed: _uploading ? null : _submit,
          child: Text(L10n.t('提交')),
        ),
      ],
    );
  }
}
