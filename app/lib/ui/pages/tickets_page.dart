import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/app_paths.dart';
import '../../core/logger.dart';
import '../../core/safe_url.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/panel_api_client.dart';
import '../../data/models/ticket.dart';
import '../app_scope.dart';
import '../auto_refresh_mixin.dart';
import '../theme.dart';
import '../widgets/list_toolbar.dart';
import '../widgets/page_header.dart';
import '../widgets/refresh_button.dart';
import '../widgets/section_card.dart';
import '../widgets/simple_data_table.dart';
import '../widgets/rich_html_view.dart';
import '../widgets/video_viewer.dart';
import '../widgets/tag_chip.dart';
import '../widgets/multiline_content_field.dart';
import '../widgets/overlay_scroll_view.dart';
import '../../l10n/l10n.dart';

class TicketsPage extends StatefulWidget {
  const TicketsPage({super.key, this.showBackButton = false});

  final bool showBackButton;

  @override
  State<TicketsPage> createState() => _TicketsPageState();
}

class _TicketsPageState extends State<TicketsPage>
    with AutoRefreshMixin<TicketsPage> {
  List<TicketSummary> _tickets = const <TicketSummary>[];
  int _page = 1;
  int _lastPage = 1;
  int _total = 0;
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
      startAutoRefresh(() => _load(silent: true));
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (api == null || (silent && _busy)) {
      return;
    }
    if (!silent) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    await loadLatest(
      () => api.fetchTickets(
        page: _page,
        length: ListToolbar.pageSize,
        search: _search,
      ),
      silent: silent,
      onData: (TicketListPage result) {
        setState(() {
          _tickets = result.tickets;
          _page = result.currentPage;
          _lastPage = result.lastPage;
          _total = result.total;
          _banned = result.banned;
          if (!silent) {
            _busy = false;
          }
          _error = null;
        });
      },
      onError: (Object e) {
        setState(() {
          _error = e is ApiException
              ? e.message
              : L10n.t('加载失败：{0}', <Object>[e]);
          _busy = false;
        });
      },
    );
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
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: AppTheme.pageScrollPadding.copyWith(left: 0, top: 0),
          children: <Widget>[
            PageHeader(
              title: L10n.t('工单'),
              showBackButton: widget.showBackButton,
              showUserAvatar: widget.showBackButton,
              actions: <Widget>[
                RefreshButton(tooltip: L10n.t('刷新工单'), onRefresh: _load),
              ],
            ),
            ListToolbar(
              currentPage: _page,
              lastPage: _lastPage,
              total: _total,
              searchHint: L10n.t('标题 / 工单号'),
              onSearchChanged: _onSearch,
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
            Padding(
              padding: EdgeInsets.only(left: AppTheme.pageScrollPadding.left),
              child: SelectionArea(
                contextMenuBuilder: AppTheme.selectableRegionMenu,
                child: Column(
                  children: <Widget>[
                    SectionCard(
                      padding: const EdgeInsets.fromLTRB(12, 20, 12, 20),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              L10n.t('如需与我们沟通，请点击创建工单按钮。'),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(fontSize: AppTheme.pageHintSize),
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.icon(
                            onPressed: _busy || _banned ? null : _create,
                            icon: const Icon(Icons.add, size: 16),
                            label: Text(L10n.t('创建工单')),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_busy && _tickets.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 80),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_error != null && _tickets.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 80),
                        child: Column(
                          children: <Widget>[
                            Icon(
                              Icons.error_outline,
                              size: 40,
                              color: Theme.of(context).colorScheme.error,
                            ),
                            const SizedBox(height: 12),
                            Text(_error!, textAlign: TextAlign.center),
                          ],
                        ),
                      )
                    else
                      SimpleDataTable(
                        columns: <String>[
                          L10n.t('操作'),
                          L10n.t('标题'),
                          L10n.t('状态'),
                          L10n.t('创建时间'),
                          L10n.t('最后回复时间'),
                        ],
                        emptyText: _search.isEmpty
                            ? L10n.t('您目前还没有工单沟通记录')
                            : L10n.t('没有匹配结果'),
                        rows: <List<Widget>>[
                          for (final TicketSummary ticket in _tickets)
                            <Widget>[
                              Align(
                                alignment: Alignment.centerLeft,
                                child: FilledButton(
                                  onPressed: () =>
                                      unawaited(_openDetail(ticket.id)),
                                  child: Text(L10n.t('查看')),
                                ),
                              ),
                              TableText('${ticket.title} (#${ticket.id})'),
                              TableText(ticket.statusText),
                              TableText(ticket.datetime, muted: true),
                              TableText(
                                ticket.lastReplyTime.isEmpty
                                    ? L10n.t('无回复')
                                    : ticket.lastReplyTime,
                                muted: true,
                              ),
                            ],
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
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

class _TicketDetailPageState extends State<_TicketDetailPage>
    with AutoRefreshMixin<_TicketDetailPage> {
  TicketDetail? _detail;
  String? _error;
  bool _busy = true;
  int _msgPage = 1;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      startAutoRefresh(() => _load(silent: true));
      unawaited(_load());
    }
  }

  Future<void> _load({bool silent = false}) async {
    final PanelApiClient? api = AppScope.of(context).auth.api;
    if (api == null || (silent && _busy)) {
      return;
    }
    if (!silent) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    await loadLatest(
      () => api.fetchTicket(widget.ticketId),
      silent: silent,
      onData: (TicketDetail detail) {
        setState(() {
          _detail = detail;
          if (!silent) {
            _msgPage = 1;
            _busy = false;
          }
          _error = null;
        });
      },
      onError: (ApiException e) {
        setState(() {
          _error = e.message;
          _busy = false;
        });
      },
    );
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
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L10n.t('关闭工单')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L10n.t('取消')),
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
        : ((allMessages.length + ListToolbar.pageSize - 1) /
                  ListToolbar.pageSize)
              .ceil();
    final int safeMsgPage = _msgPage.clamp(1, msgLastPage);
    final int msgStart = (safeMsgPage - 1) * ListToolbar.pageSize;
    final List<TicketMessage> pageMessages = allMessages.isEmpty
        ? const <TicketMessage>[]
        : allMessages.sublist(
            msgStart,
            msgStart + ListToolbar.pageSize > allMessages.length
                ? allMessages.length
                : msgStart + ListToolbar.pageSize,
          );

    final List<String> imageAlbum = detail == null
        ? const <String>[]
        : collectHtmlImageSrcs(
            detail.messages.map((TicketMessage m) => m.content),
          );

    return Scaffold(
      body: Column(
        children: <Widget>[
          SafeArea(
            bottom: false,
            child: PageHeader(
              title: detail == null
                  ? L10n.t('工单详情')
                  : '${detail.title} (#${detail.id})',
              showBackButton: true,
              showUserAvatar: true,
            ),
          ),
          Expanded(
            child: ListView(
              padding: AppTheme.pageScrollPadding.copyWith(left: 0, top: 0),
              children: <Widget>[
                if (_busy && detail == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 80),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_error != null && detail == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 80),
                    child: Center(child: Text(_error!)),
                  )
                else if (detail == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 80),
                    child: Center(child: Text(L10n.t('工单不存在'))),
                  )
                else ...<Widget>[
                  if (!detail.banned)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: <Widget>[
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
                      ),
                    ),
                  ListToolbar(
                    currentPage: safeMsgPage,
                    lastPage: msgLastPage,
                    total: allMessages.length,
                    showSearch: false,
                    onSearchChanged: (_) {},
                    onPageChanged: (int page) {
                      setState(() => _msgPage = page);
                    },
                  ),
                  SelectionArea(
                    contextMenuBuilder: AppTheme.selectableRegionMenu,
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: AppTheme.pageScrollPadding.left,
                      ),
                      child: Column(
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
                                L10n.t('共 {0} 条消息', <Object>[
                                  detail.messageCount,
                                ]),
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
                              padding: const EdgeInsets.only(top: 40),
                              child: Center(child: Text(L10n.t('暂无消息'))),
                            )
                          else
                            for (final TicketMessage message
                                in pageMessages) ...<Widget>[
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: message.isAdmin
                                      ? theme
                                            .colorScheme
                                            .surfaceContainerHighest
                                      : theme.colorScheme.surface,
                                  borderRadius: BorderRadius.circular(
                                    AppTheme.cardRadius,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
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
                                                        : theme
                                                              .colorScheme
                                                              .primary,
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
                              const SizedBox(height: 10),
                            ],
                        ],
                      ),
                    ),
                  ),
                ],
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
  const _TicketEditorResult({required this.title, required this.content});

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
      buf.write(const HtmlEscape().convert(text).replaceAll('\n', '<br>'));
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
    final List<PlatformFile> result = await FilePicker.pickFiles(
      type: video ? FileType.video : FileType.image,
    );
    if (result.isEmpty) {
      return;
    }
    await _uploadPaths(
      result.map((PlatformFile f) => f.path).whereType<String>().toList(),
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
        .where(
          (File f) => RegExp(r'app-\d{4}-\d{2}-\d{2}\.log$').hasMatch(f.path),
        )
        .toList();
    if (logs.isEmpty) {
      _toast(L10n.t('暂无运行日志'));
      return;
    }
    logs.sort(
      (File a, File b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
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
        final TicketUploadResult uploaded = await widget.api
            .uploadTicketAttachment(path);
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

  String? _httpUrl(String url) {
    if (url.isEmpty) {
      return null;
    }
    final String base = AppScope.of(context).auth.siteOrigin;
    final String abs = url.startsWith('/')
        ? '${base.replaceAll(RegExp(r'/+$'), '')}$url'
        : url;
    return SafeUrl.canLoad(abs) ? abs : null;
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
    Navigator.of(context).pop(_TicketEditorResult(title: title, content: html));
  }

  Widget _attachmentTile(int i) {
    final _TicketAttachment item = _attachments[i];
    final VoidCallback? onRemove = _uploading
        ? null
        : () => setState(() => _attachments.removeAt(i));
    if (item.kind == 'video') {
      final String? src = _httpUrl(item.url);
      if (src != null) {
        return HtmlVideoView(
          src,
          key: ValueKey<String>(src),
          onRemove: onRemove,
        );
      }
    }
    return InputChip(
      label: Text(item.name),
      avatar: Icon(switch (item.kind) {
        'image' => Icons.image_outlined,
        'video' => Icons.videocam_outlined,
        _ => Icons.attach_file,
      }, size: 16),
      onDeleted: onRemove,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.titleLabel),
      content: SizedBox(
        width: 460,
        child: OverlayScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (widget.requireTitle) ...<Widget>[
                TextField(
                  contextMenuBuilder: AppTheme.editableTextMenu,
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
                  TextButton.icon(
                    onPressed: _uploading
                        ? null
                        : () => _pickMedia(video: false),
                    icon: const Icon(Icons.image_outlined, size: 16),
                    label: Text(L10n.t('图片')),
                  ),
                  TextButton.icon(
                    onPressed: _uploading
                        ? null
                        : () => _pickMedia(video: true),
                    icon: const Icon(Icons.videocam_outlined, size: 16),
                    label: Text(L10n.t('视频')),
                  ),
                  TextButton.icon(
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
                      _attachmentTile(i),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: _uploading ? null : _submit,
          child: Text(L10n.t('提交')),
        ),
        TextButton(
          onPressed: _uploading ? null : () => Navigator.of(context).pop(),
          child: Text(L10n.t('取消')),
        ),
      ],
    );
  }
}
