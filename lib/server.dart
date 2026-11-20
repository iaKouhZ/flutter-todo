import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'windows_tls.dart';

class TodoError implements Exception {
  const TodoError(this.message);
  final String message;
  @override
  String toString() => message;
}

class LoginRequired extends TodoError {
  const LoginRequired() : super('服务器要求输入密码。');
}

class PasswordRejected extends TodoError {
  const PasswordRejected() : super('服务器未接受这个密码。');
}

class LoginThrottled extends TodoError {
  LoginThrottled(this.retryAfterSeconds) : super(
    retryAfterSeconds == null
        ? '登录尝试过多，请稍后重试。'
        : '登录尝试过多，请在 ${retryAfterSeconds ~/ 60} 分 ${retryAfterSeconds % 60} 秒后重试。',
  );

  final int? retryAfterSeconds;
}

Uri serverAddress(String input) {
  final text = input.trim();
  if (text.isEmpty) throw const TodoError('请输入服务器地址。');
  final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const TodoError('请输入站点地址，例如 https://example.com/todo/。');
  }
  final path = uri.path.replaceFirst(RegExp(r'/index\.php/?$'), '/');
  return uri.replace(path: path.endsWith('/') ? path : '$path/');
}

const tabs = {
  'tracked': '追踪中',
  'planned': '规划中',
  'done': '已完成',
  'all': '全部',
};
const statuses = {'active': '进行中', 'planned': '规划中', 'done': '已完成'};

String textOf(Element? node, String selector) =>
    node?.querySelector(selector)?.text.trim() ?? '';

class DueSubtask {
  const DueSubtask(this.title, this.deadline);
  final String title, deadline;

  static List<DueSubtask> fromRow(Element row) => row
      .querySelectorAll('.tl-row__subitems > li')
      .map((item) => DueSubtask(
        textOf(item, 'span:first-child'), textOf(item, '.tl-row__subdue'),
      ))
      .where((subtask) => subtask.title.isNotEmpty)
      .toList(growable: false);
}

class Task {
  const Task({
    required this.id,
    required this.title,
    required this.date,
    required this.deadline,
    required this.category,
    required this.status,
    required this.done,
    required this.overdue,
    required this.tracked,
    required this.pinned,
    required this.repeat,
    required this.url,
    this.dueSubtasks = const [],
  });
  final String id, title, date, deadline, category, status, repeat, url;
  final bool done, overdue, tracked, pinned;
  final List<DueSubtask> dueSubtasks;

  factory Task.fromRow(Element row) {
    final status = row.querySelector('.tl-status');
    return Task(
      id: row.attributes['data-task-id'] ?? '',
      title: textOf(row, '.tl-row__title'),
      date: row.attributes['data-due-date'] ?? row.attributes['data-occur-date'] ?? '',
      deadline: textOf(row, '.tl-row__deadline'),
      category: textOf(row, '.tl-row__cat'),
      status: statuses.keys.firstWhere(
        (key) => status?.classes.contains('tl-status--$key') ?? false,
        orElse: () => 'active',
      ),
      done: row.classes.contains('tl-row--done'),
      overdue: row.classes.contains('tl-row--overdue'),
      tracked: row.querySelector('.tl-track-mark') != null,
      pinned: row.querySelector('.tl-pin-mark') != null,
      repeat: textOf(row, '.tl-repeat-mark'),
      url: row.querySelector('.tl-row__link')?.attributes['href'] ?? '',
      dueSubtasks: DueSubtask.fromRow(row),
    );
  }
}

class TaskGroup {
  TaskGroup(this.label);
  final String label;
  final tasks = <Task>[];
}

class Feed {
  Feed(Document document) {
    name = textOf(document.documentElement, '.tl-brand__name');
    admin = document.querySelector('#bulk-form') != null;
    for (final (index, item) in document.querySelectorAll('.tl-tab').indexed) {
      if (index < tabs.length) {
        counts[tabs.keys.elementAt(index)] = textOf(item, '.tl-tab__count');
      }
    }
    for (final option in document.querySelectorAll('#tl-filter select[name="cat"] option')) {
      final value = option.attributes['value'] ?? '';
      if (value.isNotEmpty) {
        categories[value] = option.text.trim().replaceFirst(RegExp(r'\s+\(\d+\)$'), '');
      }
    }
    TaskGroup? group;
    String? section;
    for (final node in document.querySelectorAll(
      '.tl-main__scroll [data-task-row], .tl-main__scroll .tl-section-head__name, '
      '.tl-main__scroll .tl-fold__name',
    )) {
      if (!node.attributes.containsKey('data-task-row')) {
        if (node.classes.contains('tl-fold__name')) {
          section = node.text.trim();
          group = null;
        } else {
          group = TaskGroup([if (section != null) section, node.text.trim()].join(' / '));
          groups.add(group);
        }
        continue;
      }
      final task = Task.fromRow(node);
      if (task.id.isEmpty || task.title.isEmpty || task.url.isEmpty) continue;
      if (group == null) {
        group = TaskGroup(section ?? task.category);
        groups.add(group);
      }
      group.tasks.add(task);
    }
    groups.removeWhere((group) => group.tasks.isEmpty);
  }

  late final String name;
  late final bool admin;
  final counts = <String, String>{};
  final categories = <String, String>{};
  final groups = <TaskGroup>[];
}

class Subtask {
  const Subtask(this.title, this.deadline, this.done, this.index,
      {this.id = '', this.completedAt = ''});
  final String title, deadline, id, completedAt;
  final bool done;
  final int index;
}

class TaskDetail {
  TaskDetail(Document document) : root = document.querySelector('#detail') {
    if (root?.querySelector('.tl-detail__title') == null) {
      throw const TodoError('这项待办已不存在。');
    }
    for (final (index, row) in root!.querySelectorAll('.tl-detail__subitem').indexed) {
      final title = textOf(row, '.tl-detail__subtitle > span:first-child');
      final effective = row.attributes['data-completed-at'];
      final completion = effective != null && effective.length >= 16
          ? effective.substring(0, 16).replaceFirst(' ', 'T')
          : row.querySelector('input[name="completed_at"]')?.attributes['value'] ??
          RegExp(r'\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}').firstMatch(
            row.querySelectorAll('.tl-detail__subdue').map((node) => node.text).join(' '),
          )?.group(0)?.replaceFirst(' ', 'T') ?? '';
      final id = row.querySelector('input[name="subitem_id"]')?.attributes['value'] ?? '';
      subtasks.add(Subtask(title, textOf(row, '.tl-detail__subdue'),
        row.querySelector('.tl-detail__subbox--on') != null, index,
        id: id, completedAt: completion));
    }
    for (final row in root!.querySelectorAll('.tl-fact')) {
      facts[textOf(row, '.tl-fact__label')] = textOf(row, '.tl-fact__value');
    }
  }
  final Element? root;
  final subtasks = <Subtask>[];
  final facts = <String, String>{};
  String get title => textOf(root, '.tl-detail__title');
  String get body => textOf(root, '.tl-detail__body');
  bool get editableSubtasks => root?.querySelector('.tl-detail__subinput') != null;
  bool get canPin => form('pin') != null;
  String get completedAt {
    final form = completionForm;
    return form == null ? '' : input(form, 'completed_at');
  }

  Element? get completionForm {
    for (final form in root!.querySelectorAll('form')) {
      if (input(form, 'op') == 'complete' &&
          form.querySelector('input[name="completed_at"]') != null) {
        return form;
      }
    }
    return null;
  }

  Element? subtaskCompletionForm(int index) {
    final rows = root!.querySelectorAll('.tl-detail__subitem');
    if (index < 0 || index >= rows.length) return null;
    for (final form in rows[index].querySelectorAll('form')) {
      if (input(form, 'op') == 'subitem_done' &&
          form.querySelector('input[name="completed_at"]') != null) return form;
    }
    return null;
  }

  Element? form(String operation, {int? index}) {
    final rows = root!.querySelectorAll('.tl-detail__subitem');
    if (index != null && (index < 0 || index >= rows.length)) return null;
    final container = index == null ? root! : rows[index];
    for (final form in container.querySelectorAll('form')) {
      if (input(form, 'op') == operation &&
          (operation != 'complete' || form.querySelector('input[name="done"]') != null)) {
        return form;
      }
    }
    return null;
  }
}

String input(Element form, String name) =>
    form.querySelector('input[name="$name"]')?.attributes['value'] ?? '';

Map<String, String> formValues(Element form) {
  final result = <String, String>{};
  for (final field in form.querySelectorAll('input[name], select[name], textarea[name]')) {
    final name = field.attributes['name']!;
    final type = field.attributes['type'] ?? '';
    if (field.attributes.containsKey('disabled')) continue;
    if (type == 'checkbox' && !field.attributes.containsKey('checked')) continue;
    if (type == 'button' || type == 'submit' || type == 'file') continue;
    if (field.localName == 'select') {
      result[name] = (field.querySelector('option[selected]') ??
        field.querySelector('option'))?.attributes['value'] ?? '';
    } else {
      result[name] = field.localName == 'textarea' ? field.text : field.attributes['value'] ?? '';
    }
  }
  return result;
}

typedef Deadline = ({String date, String time});

class EditableSubtask {
  const EditableSubtask(this.id, this.title, this.deadline, this.index,
      {this.done = false, this.completedAt = ''});
  final String id, title, index, completedAt;
  final bool done;
  final Deadline deadline;
}

class TaskEditor {
  TaskEditor(this.form, this.page) : fields = formValues(form) {
    for (final option in form.querySelectorAll('select[name="category_id"] option')) {
      categories[option.attributes['value'] ?? ''] = option.text.trim();
    }
    final subtaskId = RegExp(r'^subitem_id\[(\d+)\]$');
    for (final entry in fields.entries) {
      final index = subtaskId.firstMatch(entry.key)?.group(1);
      if (index == null || (int.tryParse(entry.value) ?? 0) <= 0) continue;
      subtasks[entry.value] = EditableSubtask(
        entry.value,
        fields['subitem_title[$index]'] ?? '',
        (
          date: fields['subitem_due_date[$index]'] ?? '',
          time: fields['subitem_due_time[$index]'] ?? '',
        ),
        index,
        done: fields['subitem_done[$index]'] == '1' || fields['status'] == 'done',
        completedAt: fields['subitem_completed_at[$index]'] ?? '',
      );
    }
  }
  final Element form;
  final Uri page;
  final Map<String, String> fields;
  final categories = <String, String>{};
  final subtasks = <String, EditableSubtask>{};
  bool get readOnlyDetails => form.querySelector('input[name="title"][readonly]') != null;
  bool get confirmRepeat => form.querySelector('input[name="repeat_change_confirm"]') != null;

  bool canEditSubtaskTitle(EditableSubtask subtask) {
    final title = form.querySelector('input[name="subitem_title[${subtask.index}]"]');
    return fields['status'] != 'done' && title != null && title.attributes['type'] != 'hidden' &&
        !title.attributes.containsKey('readonly') && !title.attributes.containsKey('disabled');
  }
}

class _Page {
  _Page(this.url, this.status, this.body, {this.location, this.retryAfter});
  final String? location;
  final String? retryAfter;
  final Uri url;
  final int status;
  final String body;
  late final Document document = html.parse(body);
}

class TodoServer {
  TodoServer(this.base, {SecurityContext? windowsContext}) : _windowsContext = windowsContext;
  final Uri base;
  final SecurityContext? _windowsContext;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  final _cookies = <String, Cookie>{};

  void close() => _http.close(force: true);
  void forgetSession() => _cookies.clear();

  Uri _endpoint(String script, [Map<String, String>? query]) =>
      base.resolve(script).replace(queryParameters: query);

  Uri _safe(Uri url) {
    if (url.origin != base.origin || url.userInfo.isNotEmpty) {
      throw const TodoError('服务器返回了跨站地址。请填写最终的服务器地址。');
    }
    return url;
  }

  Future<_Page> _exchange(Uri target, {Map<String, String>? fields, bool ajax = false}) async {
    final client = Platform.isWindows
        ? (HttpClient(context: _windowsContext)..connectionTimeout = const Duration(seconds: 12))
        : _http;
    HttpClient? retry;
    try {
      X509Certificate? rejected;
      if (Platform.isWindows) {
        client.badCertificateCallback = (certificate, host, port) {
          if (host == target.host && port == target.port) rejected = certificate;
          return false;
        };
      }
      final method = fields == null ? 'GET' : 'POST';
      HttpClientRequest request;
      try {
        request = await client.openUrl(method, target)
            .timeout(const Duration(seconds: 15));
      } on HandshakeException {
        final certificate = rejected;
        if (!Platform.isWindows || certificate == null) rethrow;
        final verification = await verifyWindowsCertificate(certificate.der, target.host);
        if (!verification.accepted) {
          throw TodoError('HTTPS 证书校验失败：${verification.reason}');
        }
        // The failed TLS handshake happened before any HTTP body was sent.
        // Retry with the exact leaf that Windows has just fully validated.
        final verified = certificate.der;
        retry = HttpClient(context: _windowsContext)..connectionTimeout = const Duration(seconds: 12);
        retry.badCertificateCallback = (presented, host, port) =>
            matchesVerifiedCertificate(presented, verified, host, port, target);
        request = await retry.openUrl(method, target)
            .timeout(const Duration(seconds: 15));
      }
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, ajax ? 'application/json' : 'text/html');
      final now = DateTime.now();
      for (final cookie in _cookies.values) {
        if ((cookie.expires?.isAfter(now) ?? true) &&
            (!cookie.secure || target.scheme == 'https')) {
          request.cookies.add(Cookie(cookie.name, cookie.value));
        }
      }
      if (ajax) request.headers.set('X-Requested-With', 'XMLHttpRequest');
      if (fields != null) {
        request.headers.contentType = ContentType('application', 'x-www-form-urlencoded',
            charset: 'utf-8');
        request.write(Uri(queryParameters: fields).query);
      }
      final response = await request.close().timeout(const Duration(seconds: 15));
      for (final cookie in response.cookies) {
        if (cookie.value.isEmpty || (cookie.maxAge ?? 1) <= 0) {
          _cookies.remove(cookie.name);
        } else {
          _cookies[cookie.name] = cookie;
        }
      }
      final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
      return _Page(target, response.statusCode, body,
          location: response.headers.value(HttpHeaders.locationHeader),
          retryAfter: response.headers.value(HttpHeaders.retryAfterHeader));
    } finally {
      if (Platform.isWindows) client.close(force: true);
      retry?.close(force: true);
    }
  }

  Future<_Page> _request(Uri url, {Map<String, String>? fields, bool ajax = false}) async {
    for (var redirects = 0; redirects < 6; redirects++) {
      final target = _safe(url);
      final page = await _exchange(target, fields: fields, ajax: ajax);
      final location = page.location;
      if (location != null && [301, 302, 303, 307, 308].contains(page.status)) {
        if (fields != null && [307, 308].contains(page.status)) {
          throw const TodoError('服务器重定向了表单，请检查服务器地址。');
        }
        url = target.resolve(location);
        fields = null;
        continue;
      }
      return page;
    }
    throw const TodoError('服务器重定向次数过多。');
  }

  bool _isLogin(_Page page) => page.document.querySelector('.tl-gate__form') != null;

  void _check(_Page page) {
    if (page.status == 401 || page.status == 403 || _isLogin(page)) throw const LoginRequired();
    if (page.status != 200 || page.document.querySelector('.tl-brand') == null) {
      throw TodoError('无法读取待办页面（HTTP ${page.status}）。请检查服务器地址。');
    }
  }

  void _checkLoginThrottle(_Page page) {
    if (page.status != HttpStatus.tooManyRequests) return;
    final seconds = int.tryParse(page.retryAfter?.trim() ?? '');
    throw LoginThrottled(seconds != null && seconds >= 0 ? seconds : null);
  }

  Future<void> login(String password) async {
    forgetSession();
    final page = await _request(_endpoint('login.php'));
    _checkLoginThrottle(page);
    final form = page.document.querySelector('.tl-gate__form');
    final action = form?.attributes['action'];
    if (page.status != 200 || form == null || action == null || input(form, '_csrf').isEmpty) {
      throw const TodoError('无法读取服务器的密码表单。');
    }
    final result = await _request(page.url.resolve(action), fields: {
      ...formValues(form), 'password': password,
    });
    _checkLoginThrottle(result);
    if (_isLogin(result) && result.document.querySelector('.tl-gate__error') != null) {
      throw const PasswordRejected();
    }
    _check(result);
    if (result.document.querySelector('#bulk-form') == null) {
      throw const TodoError('服务器没有建立编辑会话。');
    }
  }

  Future<Feed> feed(String tab, {String category = '', String query = ''}) async {
    final page = await _request(_endpoint('index.php', {
      'tab': tab, if (category.isNotEmpty) 'cat': category,
      if (query.trim().isNotEmpty) 'q': query.trim(),
    }));
    _check(page);
    if (page.document.querySelector('.tl-main__scroll') == null) {
      throw const TodoError('服务器页面格式不兼容。');
    }
    return Feed(page.document);
  }

  Future<_Page> _detailPage(Task task) async {
    final page = await _request(base.resolve(task.url));
    _check(page);
    return page;
  }

  Future<TaskDetail> detail(Task task) async => TaskDetail((await _detailPage(task)).document);

  Future<TaskEditor> editor(Task? task) async {
    final page = await _request(_endpoint('admin.php', {
      'view': 'tasks', if (task != null) 'edit': task.id,
    }));
    _check(page);
    for (final form in page.document.querySelectorAll('form')) {
      if (input(form, 'op') == 'task_save' &&
          input(form, 'id') == (task?.id ?? '')) return TaskEditor(form, page.url);
    }
    throw const TodoError('找不到这项待办的编辑表单。');
  }

  Future<void> _submit(Uri page, Element form, Map<String, String> fields) async {
    final action = form.attributes['action'];
    if (action == null || input(form, '_csrf').isEmpty) {
      throw const TodoError('服务器表单缺少操作地址或校验字段。');
    }
    final response = await _request(page.resolve(action), ajax: true, fields: {
      ...fields, 'ajax': '1',
    });
    Map<String, dynamic>? result;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) result = decoded;
    } on FormatException {
      // An HTML response can also be the login gate.
    }
    final message = result?['message']?.toString();
    if (response.status == 401 || response.status == 403 ||
        (result == null && _isLogin(response)) ||
        (message?.contains('需要后台登录') ?? false)) {
      throw const LoginRequired();
    }
    if (response.status != 200 || result?['ok'] != true) {
      throw TodoError(message ?? '服务器未确认操作结果（HTTP ${response.status}）。');
    }
  }

  Future<void> change(Task task, String op, {int? index, Map<String, String> extra = const {}}) async {
    final page = await _detailPage(task);
    if (page.document.querySelector('#bulk-form') == null) throw const LoginRequired();
    final detail = TaskDetail(page.document);
    final editingCompletion = op == 'complete' && extra.containsKey('completed_at');
    final editingSubtaskCompletion = op == 'subitem_done' && extra.containsKey('completed_at');
    final expectedId = extra['subtask_id'];
    if (index != null && expectedId != null && expectedId.isNotEmpty) {
      index = detail.subtasks.indexWhere((subtask) => subtask.id == expectedId);
      if (index < 0) throw const TodoError('子任务已被删除，请刷新详情。');
    }
    final form = editingCompletion ? detail.completionForm :
        editingSubtaskCompletion && index != null ? detail.subtaskCompletionForm(index) :
        detail.form(op, index: index);
    if (editingCompletion && form == null) {
      throw const TodoError('任务已恢复为未完成，请刷新详情。');
    }
    if (editingSubtaskCompletion &&
        (index == null || index < 0 || index >= detail.subtasks.length ||
         !detail.subtasks[index].done || form == null)) {
      throw const TodoError('子任务已恢复为未完成，或服务器不支持编辑完成时间。请刷新详情。');
    }
    if (form == null) throw const TodoError('此任务目前不支持这项操作。');
    if (editingCompletion && ['scope', 'date'].any((key) =>
        extra.containsKey(key) && extra[key] != input(form, key))) {
      throw const TodoError('完成记录已变化，请刷新详情后再修改。');
    }
    if (form.querySelector('button[disabled]') != null) {
      throw const TodoError('此子任务目前无法修改。');
    }
    if (index != null && (index < 0 || index >= detail.subtasks.length ||
        extra['subtask_title'] != detail.subtasks[index].title)) {
      throw const TodoError('子任务列表已变化，请刷新详情后再操作。');
    }
    final fields = {
      ...formValues(form), ...extra,
      if (editingCompletion || editingSubtaskCompletion) 'done': '1',
    }..remove('subtask_title')..remove('subtask_id');
    await _submit(page.url, form, fields);
  }

  Future<void> save(Task? task, Map<String, String> changes,
      {Map<String, String> subtaskTitles = const {},
       Map<String, Deadline> subtaskDeadlines = const {},
       Map<String, String> subtaskCompletions = const {}}) async {
    final fresh = await editor(task);
    // The HTML field is only precise to the minute. Preserve the stored
    // timestamp unless the user explicitly chooses to change it.
    final fields = {...fresh.fields}..remove('completed_at');
    fields.removeWhere((key, _) => key.startsWith('subitem_completed_at['));
    fields.removeWhere((key, _) => ['tracked', 'pinned'].contains(key) && changes[key] == '');
    fields.addAll(changes);
    for (final entry in subtaskTitles.entries) {
      final subtask = fresh.subtasks[entry.key];
      if (subtask == null) {
        throw const TodoError('子任务列表已变化，请重新打开编辑页。');
      }
      if (!fresh.canEditSubtaskTitle(subtask)) {
        throw const TodoError('子任务名称目前无法修改，请重新打开编辑页。');
      }
      final title = entry.value.trim();
      if (title.isEmpty) throw const TodoError('子任务名称不能为空。');
      fields['subitem_title[${subtask.index}]'] = title;
    }
    if (subtaskDeadlines.isNotEmpty && fresh.fields['status'] == 'done') {
      throw const TodoError('主任务已完成，请先恢复为未完成，再编辑子任务截止时间。');
    }
    for (final entry in subtaskDeadlines.entries) {
      final subtask = fresh.subtasks[entry.key];
      if (subtask == null) {
        throw const TodoError('子任务列表已变化，请重新打开编辑页。');
      }
      final index = subtask.index;
      fields['subitem_due_date[$index]'] = entry.value.date;
      fields['subitem_due_time[$index]'] = entry.value.time;
    }
    for (final entry in subtaskCompletions.entries) {
      final subtask = fresh.subtasks[entry.key];
      if (subtask == null || !((changes['status'] ?? fresh.fields['status']) == 'done' ||
          fresh.fields['status'] != 'done' && subtask.done)) {
        throw const TodoError('子任务完成状态已变化，请重新打开编辑页。');
      }
      if (!fresh.fields.containsKey('subitem_completed_at[${subtask.index}]')) {
        throw const TodoError('服务器不支持编辑子任务完成时间。');
      }
      fields['subitem_completed_at[${subtask.index}]'] = entry.value;
    }
    await _submit(fresh.page, fresh.form, fields);
  }

  Future<void> delete(Task task) async {
    final fresh = await editor(task);
    await _submit(fresh.page, fresh.form, {
      '_csrf': input(fresh.form, '_csrf'), 'op': 'task_delete', 'id': task.id,
    });
  }
}
