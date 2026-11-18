import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'server.dart';
import 'desktop_settings.dart';
import 'session.dart';

const ink = Color(0xff1b1b18);
const paper = Color(0xffe8e8e2);
const raised = Color(0xfff2f2ec);
const signal = Color(0xfffff500);
const dateStyle = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);

void main() => runApp(const LedgerApp());

class LedgerApp extends StatelessWidget {
  const LedgerApp({super.key});

  ThemeData theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final background = dark ? const Color(0xff1e201d) : paper;
    final surface = dark ? const Color(0xff282a25) : raised;
    final colors = ColorScheme.fromSeed(seedColor: signal, brightness: brightness)
        .copyWith(surface: surface, primary: dark ? signal : ink,
          onPrimary: dark ? ink : Colors.white, error: dark
            ? const Color(0xffffa597) : const Color(0xffa22e20));
    const dialogShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(20)),
    );
    return ThemeData(
      colorScheme: colors,
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(backgroundColor: background, surfaceTintColor: Colors.transparent),
      dividerColor: dark ? const Color(0xff44463f) : const Color(0xffc7c7bd),
      dialogTheme: DialogThemeData(backgroundColor: surface, shape: dialogShape),
      datePickerTheme: const DatePickerThemeData(shape: dialogShape),
      timePickerTheme: const TimePickerThemeData(shape: dialogShape),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.zero),
      ),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
        backgroundColor: signal, foregroundColor: ink,
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      )),
      useMaterial3: true,
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '待办清单',
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: theme(Brightness.light),
    darkTheme: theme(Brightness.dark),
    debugShowCheckedModeBanner: false,
    home: const Workspace(),
  );
}

class Workspace extends StatefulWidget {
  const Workspace({super.key});

  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> with WidgetsBindingObserver {
  final session = Session();
  bool passwordPromptOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(session.initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && session.initialized &&
        session.feed != null && !session.arrangingServer && !passwordPromptOpen) {
      unawaited(refreshOnResume());
    }
  }

  Future<void> refreshOnResume() async {
    await session.refresh();
    if (!mounted || session.gate == null || !Navigator.of(context).canPop()) return;
    final signedIn = await askPassword(session.gate!);
    if (!signedIn && mounted && !passwordPromptOpen && session.gate != null) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.dispose();
    super.dispose();
  }

  void notice(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(readableError(error))));
  }

  Future<bool> askPassword(String reason) async {
    if (passwordPromptOpen) return false;
    passwordPromptOpen = true;
    try {
      return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PasswordDialog(session: session, reason: reason),
      ) ?? false;
    } finally {
      passwordPromptOpen = false;
    }
  }

  Future<bool> allowWrite() async {
    if (session.admin) return true;
    return askPassword(session.gate ?? '当前以访客身份浏览。输入密码后即可修改待办。');
  }

  Future<T?> protected<T>(Future<T> Function() action) async {
    try {
      return await session.authorized(action);
    } on LoginRequired {
      if (!mounted || !await askPassword(session.gate ?? '登录凭证已失效，请重新输入密码。')) {
        return null;
      }
      return session.authorized(action);
    }
  }

  Future<void> openEditor(Task? task) async {
    try {
      if (!await allowWrite() || !mounted) return;
      final model = await protected(() => session.server!.editor(task));
      if (!mounted || model == null) return;
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => EditScreen(model: model, save: (changes, deadlines) async {
          final saved = await protected(() async {
            await session.server!.save(task, changes, subtaskDeadlines: deadlines);
            return true;
          });
          if (saved == true) await session.didWrite();
          return saved == true;
        }),
      ));
    } catch (e) {
      notice(e);
    }
  }

  Future<void> openDetail(Task task) async {
    try {
      final detail = await protected(() => session.server!.detail(task));
      if (!mounted || detail == null) return;
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => DetailScreen(
          task: task, initial: detail,
          edit: () => openEditor(task),
          authorize: allowWrite,
          change: (op, index, extra) async {
            if (!await allowWrite()) return false;
            final updated = await protected(() async {
              if (op == 'task_delete') {
                await session.server!.delete(task);
              } else {
                await session.server!.change(task, op, index: index, extra: extra);
              }
              return true;
            });
            if (updated == true) await session.didWrite();
            return updated == true;
          },
          reload: () async => await protected(() => session.server!.detail(task)) ??
            (throw const LoginRequired()),
        ),
      ));
    } catch (e) {
      notice(e);
    }
  }

  Future<void> filter() async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => FilterDialog(session: session),
    );
    if (result != null) {
      await session.refresh(nextCategory: result.$1, nextQuery: result.$2);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      if (!session.initialized) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (session.server == null || session.arrangingServer ||
          session.feed == null && session.gate == null && session.error != null) {
        return GateScreen(
          key: ValueKey(session.server?.base.toString()),
          reason: session.error ?? '输入待办清单的站点地址。',
          label: '服务器地址',
          submitLabel: '连接',
          initial: session.server?.base.toString() ?? '',
          onCancel: session.server == null ? null : session.chooseServer,
          submit: session.setServer,
        );
      }
      if (session.gate != null && session.feed == null) {
        return GateScreen(
          reason: session.gate!,
          label: '服务器密码',
          submitLabel: '登录',
          secret: true,
          submit: session.signIn,
          onCancel: session.chooseServer,
          onGuest: session.gate!.startsWith('保存的密码') ? session.visitAsGuest : null,
        );
      }
      final feed = session.feed;
      return Scaffold(
        appBar: AppBar(
          title: Text(feed?.name.isNotEmpty == true ? feed!.name : '待办清单',
            style: const TextStyle(fontWeight: FontWeight.w900)),
          actions: [
            if (Platform.isWindows)
              IconButton(
                tooltip: '电脑版设置',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(builder: (_) => const DesktopSettingsScreen())),
              ),
            IconButton(onPressed: feed == null || session.busy ? null : filter,
              tooltip: '搜索与筛选', icon: const Icon(Icons.tune)),
            PopupMenuButton<String>(
              tooltip: '账户与服务器',
              enabled: !session.busy,
              onSelected: (option) async {
                try {
                  if (option == 'server') session.chooseServer();
                  if (option == 'login') await askPassword('输入服务器密码。');
                  if (option == 'logout') await session.signOut();
                } catch (e) {
                  notice(e);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: session.admin ? 'logout' : 'login',
                  child: Text(session.admin ? '退出登录' : '登录')),
                const PopupMenuItem(value: 'server', child: Text('服务器地址')),
              ],
            ),
          ],
        ),
        floatingActionButton: feed == null ? null : FloatingActionButton.extended(
          backgroundColor: signal, foregroundColor: ink,
          onPressed: session.busy ? null : () => openEditor(null),
          icon: const Icon(Icons.add), label: const Text('新增待办'),
        ),
        body: SafeArea(
          child: Column(children: [
            if (feed != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(children: [
                  Expanded(child: Text(tabs[session.tab]!,
                    style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900))),
                  Text(session.admin ? '编辑模式' : '访客 · 只读'),
                ]),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: tabs.entries.map((entry) {
                    final selected = entry.key == session.tab;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: ChoiceChip(
                        label: Text('${entry.value}  ${feed.counts[entry.key] ?? ''}'),
                        selected: selected,
                        selectedColor: signal,
                        showCheckmark: false,
                        labelStyle: selected ? const TextStyle(color: ink,
                          fontWeight: FontWeight.w800) : null,
                        onSelected: session.busy ? null :
                          (_) => session.refresh(nextTab: entry.key),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
            if (session.busy) const LinearProgressIndicator(),
            if (session.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  Expanded(child: Text(session.error!)),
                  TextButton(onPressed: session.busy ? null : session.refresh,
                    child: const Text('重试')),
                ]),
              ),
            if (feed == null) const Spacer()
            else Expanded(
              child: RefreshIndicator(
                onRefresh: session.refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 92),
                  children: [
                    if (session.query.isNotEmpty || session.category.isNotEmpty)
                      Align(alignment: Alignment.centerLeft, child: InputChip(
                        label: Text([
                          if (session.category.isNotEmpty)
                            feed.categories[session.category] ?? '分类',
                          if (session.query.isNotEmpty) session.query,
                        ].join(' · ')),
                        onDeleted: session.busy ? null :
                          () => session.refresh(nextCategory: '', nextQuery: ''),
                      )),
                    if (feed.groups.isEmpty)
                      const Padding(padding: EdgeInsets.symmetric(vertical: 44),
                        child: Center(child: Text('暂无事项'))),
                    for (final group in feed.groups) ...[
                      Padding(padding: const EdgeInsets.only(top: 16, bottom: 8),
                        child: Row(children: [
                          Container(width: 7, height: 14, color: signal),
                          const SizedBox(width: 8),
                          Expanded(child: Text(group.label,
                            style: const TextStyle(fontWeight: FontWeight.w800))),
                          Text('${group.tasks.length}', style: dateStyle),
                        ])),
                      for (final task in group.tasks)
                        TaskTile(task: task, open: () => openDetail(task),
                          complete: session.busy ? null : () async {
                            try {
                              if (!await allowWrite()) return;
                              final changed = await protected(() async {
                                await session.server!.change(task, 'complete',
                                  extra: {'done': task.done ? '0' : '1'});
                                return true;
                              });
                              if (changed == true) await session.didWrite();
                            } catch (e) {
                              notice(e);
                            }
                          }),
                    ],
                  ],
                ),
              ),
            ),
          ]),
        ),
      );
    },
  );
}

class TaskTile extends StatelessWidget {
  const TaskTile({super.key, required this.task, required this.open, this.complete});
  final Task task;
  final VoidCallback open;
  final VoidCallback? complete;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface,
      border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.only(left: 3, right: 10),
          onTap: open,
          leading: Checkbox(value: task.done, onChanged: complete == null ? null : (_) => complete!(),
            semanticLabel: task.done ? '标记未完成' : '标记完成'),
          title: Text(task.title, style: TextStyle(fontWeight: FontWeight.w700,
            decoration: task.done ? TextDecoration.lineThrough : null)),
          subtitle: Text([
            if (task.deadline.isNotEmpty) task.deadline,
            if (task.pinned) '置顶',
            if (task.tracked) '追踪',
            if (task.repeat.isNotEmpty) task.repeat,
          ].join(' · '), style: dateStyle.copyWith(
            color: task.overdue ? Theme.of(context).colorScheme.error : null)),
          trailing: const Icon(Icons.chevron_right),
        ),
        if (task.dueSubtasks.isNotEmpty)
          InkWell(
            onTap: open,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(58, 0, 14, 8),
              child: Column(
                children: [
                  for (final subtask in task.dueSubtasks)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(right: 5),
                            child: Icon(Icons.subdirectory_arrow_right, size: 15),
                          ),
                          Expanded(child: Text(subtask.title)),
                          const SizedBox(width: 8),
                          Text(subtask.deadline, style: dateStyle.copyWith(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          )),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

class GateScreen extends StatefulWidget {
  const GateScreen({super.key, required this.label, required this.reason,
    required this.submitLabel, required this.submit, this.initial = '',
    this.secret = false, this.onCancel, this.onGuest});
  final String label, reason, submitLabel, initial;
  final bool secret;
  final Future<void> Function(String) submit;
  final VoidCallback? onCancel;
  final Future<void> Function()? onGuest;

  @override
  State<GateScreen> createState() => _GateScreenState();
}

class _GateScreenState extends State<GateScreen> {
  late final text = TextEditingController(text: widget.initial);
  bool busy = false;
  String? error;

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try {
      await widget.submit(text.text);
    } catch (e) {
      if (mounted) setState(() => error = readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('待办清单', style: TextStyle(fontSize: 52,
                fontWeight: FontWeight.w900, letterSpacing: -2)),
              const Align(alignment: Alignment.centerLeft,
                child: ColoredBox(color: signal, child: SizedBox(width: 72, height: 5))),
              const SizedBox(height: 32),
              Text(widget.reason),
              const SizedBox(height: 16),
              TextField(controller: text, enabled: !busy, obscureText: widget.secret,
                autocorrect: false, enableSuggestions: false,
                keyboardType: widget.secret ? TextInputType.visiblePassword : TextInputType.url,
                textInputAction: TextInputAction.go, onSubmitted: (_) => submit(),
                decoration: InputDecoration(labelText: widget.label, errorText: error,
                  errorMaxLines: 3, hintText: widget.secret ? null : 'https://example.com/todo/')),
              const SizedBox(height: 18),
              FilledButton(onPressed: busy ? null : submit, child: Text(widget.submitLabel)),
              if (busy) const LinearProgressIndicator(),
              if (widget.onGuest != null)
                TextButton(onPressed: busy ? null : widget.onGuest, child: const Text('尝试以访客继续')),
              if (widget.onCancel != null)
                TextButton(onPressed: busy ? null : widget.onCancel,
                  child: Text(widget.secret ? '更换服务器地址' : '返回')),
            ]),
          ),
        ),
      ),
    ),
  );
}

class PasswordDialog extends StatefulWidget {
  const PasswordDialog({super.key, required this.session, required this.reason});
  final Session session;
  final String reason;

  @override
  State<PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<PasswordDialog> {
  final text = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try {
      await widget.session.signIn(text.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() { busy = false; error = readableError(e); });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('输入服务器密码'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.reason),
          const SizedBox(height: 16),
          TextField(controller: text, obscureText: true, autofocus: true, enabled: !busy,
            autocorrect: false, enableSuggestions: false, onSubmitted: (_) => submit(),
            decoration: InputDecoration(labelText: '密码', errorText: error, errorMaxLines: 3)),
        ]),
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: busy ? null : submit, child: const Text('登录')),
      ],
    ),
  );
}

class FilterDialog extends StatefulWidget {
  const FilterDialog({super.key, required this.session});
  final Session session;

  @override
  State<FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<FilterDialog> {
  late final query = TextEditingController(text: widget.session.query);
  late String category = widget.session.category;

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categories = {'': '全部分类', ...widget.session.feed!.categories};
    return AlertDialog(
      title: const Text('搜索与筛选'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: query, decoration: const InputDecoration(labelText: '摘要 / 详情 / 分类'),
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => Navigator.pop(context, (category, query.text))),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: categories.containsKey(category) ? category : '',
            isExpanded: true,
            decoration: const InputDecoration(labelText: '分类'),
            items: categories.entries.map((e) =>
              DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))).toList(),
            onChanged: (value) => setState(() => category = value ?? ''),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, ('', '')), child: const Text('清除')),
        FilledButton(onPressed: () => Navigator.pop(context, (category, query.text)),
          child: const Text('应用')),
      ],
    );
  }
}

typedef TaskChange = Future<bool> Function(String, int?, Map<String, String>);

class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.task, required this.initial, required this.edit,
    required this.authorize, required this.change, required this.reload});
  final Task task;
  final TaskDetail initial;
  final Future<void> Function() edit;
  final Future<bool> Function() authorize;
  final TaskChange change;
  final Future<TaskDetail> Function() reload;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late TaskDetail detail = widget.initial;
  bool busy = false;

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(readableError(e))));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> change(String op, {int? index, Map<String, String> extra = const {}}) async {
    await run(() async {
      if (!await widget.change(op, index, extra) || !mounted) return;
      if (op == 'task_delete') {
        Navigator.pop(context);
      } else {
        detail = await widget.reload();
      }
    });
  }

  Future<bool> confirm(String text) async => await showDialog<bool>(context: context,
    builder: (context) => AlertDialog(
      title: Text(text),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
      ],
    )) ?? false;

  Future<void> addSubtask() async {
    final result = await showDialog<ScheduleResult>(
      context: context,
      builder: (_) => const ScheduleDialog(label: '添加子任务', withTitle: true),
    );
    if (result == null || !mounted) return;
    await change('subitem_add', extra: {
      'title': result.title,
      'due_date': result.deadline.date,
      'due_time': result.deadline.time,
    });
  }

  Future<void> editCompletion() => run(() async {
    if (!await widget.authorize() || !mounted) return;
    detail = await widget.reload();
    if (!mounted) return;
    final form = detail.completionForm;
    if (form == null) {
      throw const TodoError('这项待办目前没有可编辑的完成时间。');
    }
    final result = await showDialog<ScheduleResult>(
      context: context,
      builder: (_) => ScheduleDialog(
        label: '编辑完成时间',
        initial: splitCompletion(detail.completedAt),
        completion: true,
      ),
    );
    if (result == null || !mounted) return;
    final stamp = completionStamp(result.deadline);
    if (stamp == detail.completedAt) return;
    if (await widget.change('complete', null, {
      'completed_at': stamp, 'scope': input(form, 'scope'), 'date': input(form, 'date'),
    }) && mounted) {
      detail = await widget.reload();
    }
  });

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    bool active(String op, String field) {
      final form = detail.form(op);
      return form != null && input(form, field) == '0';
    }
    final done = detail.facts.containsKey('完成') || active('complete', 'done');
    final tracked = active('track', 'tracked');
    final pinned = active('pin', 'pinned');
    final isGuestDetail = detail.form('complete') == null;
    final canAddSubtask = detail.editableSubtasks ||
      (isGuestDetail && task.repeat.isEmpty && !task.done);
    return Scaffold(
      appBar: AppBar(title: const Text('任务详情'), actions: [
        IconButton(tooltip: '编辑', onPressed: busy ? null : () => run(() async {
          await widget.edit();
          detail = await widget.reload();
        }), icon: const Icon(Icons.edit_outlined)),
        IconButton(tooltip: '删除', onPressed: busy ? null : () async {
          if (await confirm('删除这项待办？') && mounted) await change('task_delete');
        }, icon: const Icon(Icons.delete_outline)),
      ]),
      body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [
        if (busy) const LinearProgressIndicator(),
        Text(detail.title, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
        const SizedBox(height: 12),
        for (final fact in detail.facts.entries)
          Padding(padding: const EdgeInsets.only(bottom: 6),
            child: Text('${fact.key}   ${fact.value}', style: dateStyle)),
        const Divider(height: 28),
        SelectableText(detail.body),
        const SizedBox(height: 20),
        Wrap(spacing: 8, runSpacing: 6, children: [
          FilledButton(onPressed: busy ? null : () => change('complete', extra: {
            'done': (isGuestDetail ? task.done : done) ? '0' : '1',
          }), child: Text((isGuestDetail ? task.done : done) ? '恢复未完成' : '标记完成')),
          if (detail.completionForm != null || (isGuestDetail && done))
            OutlinedButton(onPressed: busy ? null : editCompletion,
              child: const Text('编辑完成时间')),
          OutlinedButton(onPressed: busy ? null : () => change('track', extra: {
            'tracked': (isGuestDetail ? task.tracked : tracked) ? '0' : '1',
          }), child: Text((isGuestDetail ? task.tracked : tracked) ? '取消追踪' : '添加追踪')),
          if (detail.canPin || isGuestDetail)
            OutlinedButton(onPressed: busy ? null : () => change('pin', extra: {
              'pinned': (isGuestDetail ? task.pinned : pinned) ? '0' : '1',
            }), child: Text((isGuestDetail ? task.pinned : pinned) ? '取消置顶' : '置顶')),
        ]),
        if (detail.subtasks.isNotEmpty || canAddSubtask) ...[
          const Divider(height: 36),
          Row(children: [
            const Expanded(child: Text('子任务', style: TextStyle(fontWeight: FontWeight.w900))),
            if (canAddSubtask)
              TextButton(onPressed: busy ? null : addSubtask, child: const Text('添加')),
          ]),
          for (final sub in detail.subtasks)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Checkbox(value: sub.done,
                onChanged: busy || task.status == 'done' && isGuestDetail || !isGuestDetail &&
                    detail.form('subitem_done', index: sub.index)?.querySelector('button[disabled]') != null
                  ? null : (_) => change('subitem_done', index: sub.index,
                    extra: {'subtask_title': sub.title, 'done': sub.done ? '0' : '1'})),
              title: Text(sub.title),
              subtitle: sub.deadline.isEmpty ? null : Text(sub.deadline, style: dateStyle),
              trailing: canAddSubtask ? IconButton(tooltip: '删除子任务',
                icon: const Icon(Icons.close),
                onPressed: busy ? null : () async {
                  if (await confirm('删除这条子任务？') && mounted) {
                    await change('subitem_delete', index: sub.index, extra: {'subtask_title': sub.title});
                  }
                }) : null,
            ),
        ],
      ])),
    );
  }
}

typedef ScheduleResult = ({String title, Deadline deadline});

Deadline splitCompletion(String value) {
  final parts = value.split('T');
  return parts.length == 2
      ? (date: parts[0], time: parts[1])
      : (date: '', time: '');
}

String completionStamp(Deadline value) => '${value.date}T${value.time}';

class DeadlineFields extends StatelessWidget {
  const DeadlineFields({
    super.key,
    required this.value,
    required this.onChanged,
    this.completion = false,
  });

  final Deadline value;
  final ValueChanged<Deadline>? onChanged;
  final bool completion;

  Future<void> pickDate(BuildContext context) async {
    final initial = DateTime.tryParse(value.date) ?? DateTime.now();
    final earliest = DateTime(1900);
    final latest = DateTime(2100, 12, 31);
    final selected = await showDatePicker(
      context: context,
      firstDate: initial.isBefore(earliest) ? initial : earliest,
      lastDate: initial.isAfter(latest) ? initial : latest,
      initialDate: initial,
    );
    if (selected == null || !context.mounted) return;
    onChanged?.call((date: selected.toIso8601String().substring(0, 10), time: value.time));
  }

  Future<void> pickTime(BuildContext context) async {
    final parsed = DateTime.tryParse('${value.date}T${value.time}Z');
    final selected = await showTimePicker(
      context: context,
      initialTime: parsed != null ? TimeOfDay.fromDateTime(parsed) :
          completion ? TimeOfDay.now() : const TimeOfDay(hour: 18, minute: 0),
    );
    if (selected == null || !context.mounted) return;
    final hour = selected.hour.toString().padLeft(2, '0');
    final minute = selected.minute.toString().padLeft(2, '0');
    onChanged?.call((date: value.date, time: '$hour:$minute'));
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 6,
    children: [
      OutlinedButton(
        onPressed: onChanged == null ? null : () => pickDate(context),
        child: Text(value.date.isNotEmpty ? value.date :
            completion ? '选完成日期' : '选截止日期', style: dateStyle),
      ),
      OutlinedButton(
        onPressed: onChanged == null || value.date.isEmpty ? null : () => pickTime(context),
        child: Text(value.time.isNotEmpty ? value.time :
            completion ? '选完成时刻' : '选截止时刻', style: dateStyle),
      ),
      if (!completion && value.date.isNotEmpty)
        TextButton(
          onPressed: onChanged == null ? null :
            () => onChanged!((date: '', time: '')),
          child: const Text('清除截止'),
        ),
      if (!completion && value.time.isNotEmpty)
        TextButton(
          onPressed: onChanged == null ? null :
            () => onChanged!((date: value.date, time: '')),
          child: const Text('仅清除时刻'),
        ),
    ],
  );
}

class ScheduleDialog extends StatefulWidget {
  const ScheduleDialog({
    super.key,
    required this.label,
    this.initial = (date: '', time: ''),
    this.withTitle = false,
    this.completion = false,
  });

  final String label;
  final Deadline initial;
  final bool withTitle, completion;

  @override
  State<ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<ScheduleDialog> {
  final title = TextEditingController();
  late Deadline deadline = widget.initial;

  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = (!widget.withTitle || title.text.trim().isNotEmpty) &&
        (!widget.completion || deadline.date.isNotEmpty && deadline.time.isNotEmpty);
    return AlertDialog(
      title: Text(widget.label),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.withTitle)
              TextField(
                controller: title,
                autofocus: true,
                maxLength: 200,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: '摘要'),
              ),
            if (widget.completion) const Text('日期和时刻按服务器时区填写。'),
            DeadlineFields(
              value: deadline,
              onChanged: (value) => setState(() => deadline = value),
              completion: widget.completion,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: !valid ? null :
            () => Navigator.pop(context, (title: title.text.trim(), deadline: deadline)),
          child: Text(widget.withTitle ? '添加' : '保存'),
        ),
      ],
    );
  }
}

class EditScreen extends StatefulWidget {
  const EditScreen({super.key, required this.model, required this.save});
  final TaskEditor model;
  final Future<bool> Function(Map<String, String>, Map<String, Deadline>) save;

  @override
  State<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends State<EditScreen> {
  late final title = TextEditingController(text: field('title'));
  late final body = TextEditingController(text: field('detail'));
  late final interval = TextEditingController(text: field('repeat_interval', '1'));
  late String category = field('category_id');
  late Deadline deadline = (date: field('due_date'), time: field('due_time'));
  late Deadline completion = splitCompletion(field('completed_at'));
  final subtaskDeadlines = <String, Deadline>{};
  late String status = field('status', 'active');
  late String unit = field('repeat_unit');
  late bool tracked = field('tracked') == '1';
  late bool pinned = field('pinned') == '1';
  bool confirmed = false;
  bool busy = false;
  String? error;

  String field(String name, [String fallback = '']) => widget.model.fields[name] ?? fallback;

  @override
  void dispose() {
    title.dispose();
    body.dispose();
    interval.dispose();
    super.dispose();
  }

  Future<void> editSubtaskDeadline(EditableSubtask subtask) async {
    final result = await showDialog<ScheduleResult>(
      context: context,
      builder: (_) => ScheduleDialog(
        label: '编辑子任务截止时间',
        initial: subtaskDeadlines[subtask.id] ?? subtask.deadline,
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      if (result.deadline == subtask.deadline) {
        subtaskDeadlines.remove(subtask.id);
      } else {
        subtaskDeadlines[subtask.id] = result.deadline;
      }
    });
  }

  Future<void> editCompletion() async {
    final result = await showDialog<ScheduleResult>(
      context: context,
      builder: (_) => ScheduleDialog(
        label: '编辑完成时间', initial: completion, completion: true,
      ),
    );
    if (mounted && result != null) setState(() => completion = result.deadline);
  }

  Future<void> submit() async {
    if (busy) return;
    if (title.text.trim().isEmpty) {
      setState(() => error = '请输入摘要。');
      return;
    }
    final step = int.tryParse(interval.text);
    if (!widget.model.course && unit.isNotEmpty &&
        (deadline.date.isEmpty || step == null || step < 1 || step > 365)) {
      setState(() => error = '重复任务需要截止日期，重复间隔为 1–365。');
      return;
    }
    final course = widget.model.course;
    setState(() { busy = true; error = null; });
    try {
      final changes = {
        if (!course) ...{
          'title': title.text.trim(), 'detail': body.text, 'category_id': category,
          'due_date': deadline.date, 'due_time': deadline.time,
          'repeat_unit': unit, 'repeat_interval': interval.text, 'pinned': pinned ? '1' : '',
          if (confirmed) 'repeat_change_confirm': '1',
        },
        'status': status, 'tracked': tracked ? '1' : '',
        if (status == 'done' && completion.date.isNotEmpty &&
            completionStamp(completion) != field('completed_at'))
          'completed_at': completionStamp(completion),
      }..removeWhere((key, value) => key != 'repeat_change_confirm' && value == field(key));
      final saved = await widget.save(changes, Map.of(subtaskDeadlines));
      if (saved && mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget select(String label, Map<String, String> choices, String current, ValueChanged<String> update) =>
    DropdownButtonFormField<String>(
      initialValue: choices.containsKey(current) ? current : choices.keys.first,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: choices.entries.map((e) => DropdownMenuItem(
        value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))).toList(),
      onChanged: busy ? null : (value) { if (value != null) setState(() => update(value)); },
    );

  @override
  Widget build(BuildContext context) {
    final course = widget.model.course;
    return PopScope(canPop: !busy, child: Scaffold(
      appBar: AppBar(title: Text(field('id').isEmpty ? '新增待办' : '编辑待办')),
      body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: title, readOnly: course || busy, maxLength: 140,
          decoration: const InputDecoration(labelText: '摘要')),
        TextField(controller: body, readOnly: course || busy, minLines: 3, maxLines: 7,
          decoration: const InputDecoration(labelText: '详情')),
        const SizedBox(height: 12),
        if (course)
          const Padding(padding: EdgeInsets.only(bottom: 12), child: Text('课程表事项可修改状态和追踪。'))
        else ...[
          select('分类', {'': '未分类', ...widget.model.categories}, category, (v) => category = v),
          const SizedBox(height: 12),
          DeadlineFields(value: deadline,
            onChanged: busy ? null : (value) => setState(() => deadline = value)),
          const SizedBox(height: 12),
          select('重复', const {'': '不重复', 'day': '按天', 'week': '按周', 'month': '按月'},
            unit, (v) => unit = v),
          if (unit.isNotEmpty) ...[
            const SizedBox(height: 12),
            TextField(controller: interval, keyboardType: TextInputType.number, enabled: !busy,
              decoration: const InputDecoration(labelText: '重复间隔')),
          ],
          if (widget.model.confirmRepeat)
            CheckboxListTile(contentPadding: EdgeInsets.zero,
              title: const Text('确认调整重复规则'),
              subtitle: const Text('调整后可能移除与新规则不符的单次完成记录。'),
              value: confirmed, onChanged: busy ? null : (v) => setState(() => confirmed = v ?? false)),
          const SizedBox(height: 12),
        ],
        select('状态', statuses, status, (v) => status = v),
        if (status == 'done')
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('完成时间'),
            subtitle: Text(completion.date.isEmpty ? '由服务器记录' :
              '${completion.date} ${completion.time}', style: dateStyle),
            trailing: const Icon(Icons.edit_outlined),
            onTap: busy ? null : editCompletion,
          ),
        if (widget.model.subtasks.isNotEmpty) ...[
          const Divider(),
          const Text('子任务截止时间', style: TextStyle(fontWeight: FontWeight.w900)),
          if (field('status') == 'done')
            const Text('先将主任务恢复为未完成，即可修改子任务。'),
          for (final subtask in widget.model.subtasks.values)
            Builder(builder: (context) {
              final due = subtaskDeadlines[subtask.id] ?? subtask.deadline;
              final editable = !busy && field('status') != 'done';
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(subtask.title),
                subtitle: Text(due.date.isEmpty ? '未设截止' :
                  [due.date, if (due.time.isNotEmpty) due.time].join(' '), style: dateStyle),
                trailing: editable ? const Icon(Icons.edit_outlined) : null,
                onTap: editable ? () => editSubtaskDeadline(subtask) : null,
              );
            }),
          const Divider(),
        ],
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('追踪'), value: tracked,
          onChanged: busy ? null : (v) => setState(() => tracked = v)),
        if (!course)
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('置顶'), value: pinned,
            onChanged: busy ? null : (v) => setState(() => pinned = v)),
        if (error != null)
          Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error))),
        FilledButton(onPressed: busy ? null : submit, child: const Text('保存')),
        if (busy) const LinearProgressIndicator(),
      ])),
    ));
  }
}
