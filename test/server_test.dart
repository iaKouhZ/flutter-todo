import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart';
import 'package:todo_endfield/server.dart';
import 'package:todo_endfield/session.dart';

const row = '''
<div class="tl-section-head__name">学习</div>
<div data-task-row data-task-id="7" data-occur-date="2026-11-21" class="tl-row">
 <a class="tl-row__link" href="/todo/tracked/task/7/2026-11-21/">
 <span class="tl-row__title">交作业</span><span class="tl-row__cat">学习</span>
 <span class="tl-row__deadline">11/21 14:00</span><span class="tl-status tl-status--active"></span>
 </a>
</div>''';

String gate({bool wrong = false}) => '''
<div class="tl-brand">待办清单</div>
<form class="tl-gate__form" method="post" action="/todo/login/">
 <input type="hidden" name="_csrf" value="test-token">
 <input type="hidden" name="back" value="/todo/index.php">
 ${wrong ? '<div class="tl-gate__error">密码不正确。</div>' : ''}
 <input type="password" name="password">
</form>''';

String home(bool admin, {bool detail = false, String? completedScope, String subtasks = ''}) => '''
<div class="tl-brand"><span class="tl-brand__name">待办清单</span></div>
${admin ? '<form id="bulk-form"></form>' : ''}
<main class="tl-main__scroll">$row</main>
${detail ? '''
<aside id="detail"><h2 class="tl-detail__title">交作业</h2>
<p class="tl-detail__body">数学</p>
${admin ? '''
${completedScope != null ? '''
<form action="/todo/action/" method="post">
 <input name="_csrf" value="test-token"><input name="op" value="complete">
 <input name="scope" value="$completedScope"><input name="date" value="2026-11-21">
 <input name="id" value="7">
 <input type="datetime-local" name="completed_at" value="2026-11-21T16:08">
</form>''' : ''}
<form action="/todo/action/" method="post">
 <input name="_csrf" value="test-token"><input name="op" value="complete">
 <input name="scope" value="occurrence"><input name="date" value="2026-11-21">
 <input name="id" value="7"><input name="done" value="1">
</form>
<form action="/todo/action/" method="post">
 <input name="_csrf" value="test-token"><input name="op" value="subitem_add">
 <input name="task_id" value="7"><input class="tl-detail__subinput" name="title">
 <input type="date" name="due_date"><input type="time" name="due_time">
</form>''' : ''}
$subtasks
</aside>''' : ''}
''';

String editorForm(List<int> ids, {bool done = false}) => '''
<div class="tl-brand">待办清单</div>
<form action="/todo/action/" method="post">
 <input name="_csrf" value="test-token"><input name="op" value="task_save">
 <input name="id" value="7"><input name="title" value="交作业">
 <select name="status"><option value="${done ? 'done' : 'active'}" selected></option></select>
 ${done ? '<input type="datetime-local" name="completed_at" value="2026-11-21T16:08">' : ''}
 ${ids.indexed.map((entry) {
   final (index, id) = entry;
   return '''
 <input name="subitem_id[$index]" value="$id">
 <input name="subitem_title[$index]" value="子任务 $id" ${done ? 'readonly' : ''}>
 <input type="date" name="subitem_due_date[$index]" value="2026-11-2$id">
 <input type="time" name="subitem_due_time[$index]" value="15:00">
 <input type="datetime-local" name="subitem_completed_at[$index]" value="${id == 2 ? '2026-11-21T16:08' : ''}">
 ${id == 2 ? '<input type="checkbox" name="subitem_done[$index]" value="1" checked ${done ? 'disabled' : ''}>' : ''}
 ''';
 }).join()}
</form>''';

String completedSubtask(int id, {bool done = true, bool parentDone = false,
    String title = '检查', String stamp = '2026-11-21T16:08', bool admin = true}) => '''
<li class="tl-detail__subitem">
 <div class="tl-detail__subtitle"><span>$title</span>
 <span class="tl-detail__subdue">${done ? '已按时完成' : '1天2小时后 · 11月21日 15:00'}</span>
 ${!admin && done ? '<span class="tl-detail__subdue">完成时间 ${stamp.replaceFirst('T', ' ')}</span>' : ''}
 </div>
 <span class="tl-detail__subbox ${done ? 'tl-detail__subbox--on' : ''}"></span>
 ${admin ? '''
 <form action="/todo/action/" method="post">
  <input name="_csrf" value="test-token"><input name="op" value="subitem_done">
  <input name="task_id" value="7"><input name="subitem_id" value="$id">
  <input name="done" value="${done ? '0' : '1'}">
  <button ${parentDone ? 'disabled' : ''}>切换状态</button>
 </form>
 ${done ? '''
 <details class="tl-detail__subcompletion"><form action="/todo/action/" method="post">
  <input name="_csrf" value="test-token"><input name="op" value="subitem_done">
  <input name="task_id" value="7"><input name="subitem_id" value="$id">
  <input type="datetime-local" name="completed_at" value="$stamp">
  <button>保存完成时间</button>
 </form></details>''' : ''}
 ''' : ''}
</li>''';

class MemoryDevice extends DeviceStore {
  final settings = <String, String>{};

  @override
  Future<Map<String, String>> read() async => Map.of(settings);

  @override
  Future<void> server(String url) async {
    settings['url'] = url;
  }

  @override
  Future<void> password(String? password) async {
    if (password == null) {
      settings.remove('password');
    } else {
      settings['password'] = password;
    }
  }

  @override
  Future<void> refreshWidget() async {}
}

void main() {
  late HttpServer http;
  late TodoServer client;
  late String password;
  late bool public;
  late int credentialVersion;
  late Map<String, String> written;
  late String? completedScope;
  late List<int> subtaskIds;
  late bool editorDone;
  late String subtaskRows;

  setUp(() async {
    password = '旧 口令 +&';
    public = true;
    credentialVersion = 1;
    written = {};
    completedScope = null;
    subtaskIds = [1, 2];
    editorDone = false;
    subtaskRows = '';
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((request) async {
      final response = request.response;
      final admin = request.cookies.any((c) => c.name == 'admin' &&
        c.value == '$credentialVersion');
      final path = request.uri.path;
      response.headers.contentType = ContentType.html;
      if (path.endsWith('login.php')) {
        response.cookies.add(Cookie('csrf', 'test-token'));
        response.write(gate());
      } else if (path == '/todo/login/') {
        final fields = Uri.splitQueryString(await utf8.decoder.bind(request).join());
        final valid = fields['_csrf'] == 'test-token' &&
          request.cookies.any((c) => c.name == 'csrf' && c.value == 'test-token') &&
          fields['password'] == password;
        if (valid) {
          response.cookies.add(Cookie('admin', '$credentialVersion'));
          response.redirect(Uri.parse('/todo/index.php'));
          return;
        }
        response.write(gate(wrong: true));
      } else if (path == '/todo/action/') {
        response.headers.contentType = ContentType.json;
        final values = Uri.splitQueryString(await utf8.decoder.bind(request).join());
        if (admin && values['_csrf'] == 'test-token') written = values;
        response.write(jsonEncode(admin ? {'ok': true} :
          {'ok': false, 'message': '需要后台登录才能操作。'}));
      } else if (path == '/todo/admin.php' && admin) {
        response.write(editorForm(subtaskIds, done: editorDone));
      } else if (path != '/todo/index.php' && !path.startsWith('/todo/tracked/task/')) {
        response.statusCode = 404;
      } else if (!public && !admin) {
        response.redirect(Uri.parse('/todo/login.php'));
        return;
      } else {
        response.write(home(admin, detail: path.startsWith('/todo/tracked/task/'),
          completedScope: completedScope, subtasks: subtaskRows));
      }
      await response.close();
    });
    client = TodoServer(serverAddress('http://127.0.0.1:${http.port}/todo'));
  });

  tearDown(() async {
    client.close();
    await http.close(force: true);
  });

  test('normalizes a subdirectory and rejects embedded credentials', () {
    expect(serverAddress('example.com/todo/index.php').toString(), 'https://example.com/todo/');
    expect(() => serverAddress('https://me:pass@example.com/todo/'), throwsA(isA<TodoError>()));
  });

  test('network errors retain their diagnostic cause', () {
    expect(readableError(const SocketException('DNS lookup failed')),
      contains('DNS lookup failed'));
    expect(readableError(const HandshakeException('Certificate chain incomplete')),
      contains('Certificate chain incomplete'));
  });

  test('guest reads a public server but cannot change it', () async {
    final feed = await client.feed('tracked');
    expect(feed.admin, isFalse);
    final task = feed.groups.single.tasks.single;
    expect(task.title, '交作业');
    expect(task.dueSubtasks, isEmpty);
    expect((await client.detail(task)).body, '数学');
    await expectLater(client.change(task, 'complete'), throwsA(isA<LoginRequired>()));
    expect(written, isEmpty);
  });

  test('private gate, CSRF login, occurrence update and password rotation', () async {
    public = false;
    await expectLater(client.feed('tracked'), throwsA(isA<LoginRequired>()));
    await expectLater(client.login('wrong'), throwsA(isA<PasswordRejected>()));
    await client.login(password);
    final feed = await client.feed('tracked');
    expect(feed.admin, isTrue);
    final task = feed.groups.single.tasks.single;
    await client.change(task, 'complete');
    expect(written, containsPair('scope', 'occurrence'));
    expect(written, containsPair('date', '2026-11-21'));
    expect(written, containsPair('ajax', '1'));
    final oldPassword = password;
    password = '新密码';
    credentialVersion++;
    await expectLater(client.change(task, 'complete'), throwsA(isA<LoginRequired>()));
    await expectLater(client.login(oldPassword), throwsA(isA<PasswordRejected>()));
    await client.login(password);
    expect((await client.feed('all')).admin, isTrue);
  });

  test('first launch persists the server, restores the password and explains rotation', () async {
    final device = MemoryDevice();
    final fresh = Session(device: device);
    addTearDown(fresh.dispose);
    await fresh.initialize();
    expect(fresh.server, isNull);
    await fresh.setServer(client.base.toString());
    expect(device.settings['url'], client.base.toString());
    expect(fresh.feed?.admin, isFalse);
    await fresh.signIn(password);
    expect(device.settings['password'], password);

    final restored = Session(device: device);
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.feed?.admin, isTrue);

    password = '新密码';
    credentialVersion++;
    await restored.refresh();
    expect(restored.feed, isNull);
    expect(restored.gate, contains('密码已失效'));
    expect(device.settings.containsKey('password'), isFalse);
    await restored.signIn(password);
    expect(restored.feed?.admin, isTrue);
  });

  test('a private server asks for a password immediately after setup', () async {
    final session = Session(device: MemoryDevice());
    addTearDown(session.dispose);
    public = false;
    await session.initialize();
    await session.setServer(client.base.toString());
    expect(session.feed, isNull);
    expect(session.gate, contains('关闭访客访问'));
  });

  test('tracked rows keep the web feed order and relative deadlines of subtasks', () async {
    final fixture = '''<main class="tl-main__scroll">
      ${row.replaceFirst('</a>', '''
      <ul class="tl-row__subitems">
        <li><span>先校对</span><span class="tl-row__subdue">今天 · 12月31日 15:00</span></li>
        <li><span>再提交</span><span class="tl-row__subdue">明天 · 1月1日</span></li>
      </ul></a>''')}
    </main>''';
    final tasks = Feed(parse(fixture)).groups.single.tasks;
    expect(tasks.single.dueSubtasks.map((s) => s.title), ['先校对', '再提交']);
    expect(tasks.single.dueSubtasks.last.deadline, '明天 · 1月1日');
  });

  test('new subtask submits its optional deadline in the detail form', () async {
    await client.login(password);
    final task = (await client.feed('tracked')).groups.single.tasks.single;
    await client.change(task, 'subitem_add', extra: {
      'title': '校对',
      'due_date': '2026-11-21',
      'due_time': '14:30',
    });
    expect(written, containsPair('op', 'subitem_add'));
    expect(written, containsPair('task_id', '7'));
    expect(written, containsPair('due_date', '2026-11-21'));
    expect(written, containsPair('due_time', '14:30'));
  });

  test('editing a deadline uses fresh row IDs and preserves untouched subtasks', () async {
    await client.login(password);
    final task = (await client.feed('tracked')).groups.single.tasks.single;
    final form = await client.editor(task);
    expect(form.subtasks['1']?.deadline, (date: '2026-11-21', time: '15:00'));

    subtaskIds = [2, 1];
    await client.save(task, {}, subtaskDeadlines: {'1': (date: '', time: '')});
    expect(written, containsPair('subitem_id[0]', '2'));
    expect(written, containsPair('subitem_due_date[0]', '2026-11-22'));
    expect(written, containsPair('subitem_due_time[0]', '15:00'));
    expect(written, containsPair('subitem_done[0]', '1'));
    expect(written, containsPair('subitem_id[1]', '1'));
    expect(written, containsPair('subitem_title[1]', '子任务 1'));
    expect(written, containsPair('subitem_due_date[1]', ''));
    expect(written, containsPair('subitem_due_time[1]', ''));

    subtaskIds = [2];
    written = {};
    await expectLater(client.save(task, {}, subtaskDeadlines: {'1': (date: '', time: '')}),
      throwsA(isA<TodoError>()));
    expect(written, isEmpty);
  });

  test('renaming a subtask uses its fresh row ID and preserves its deadline and completion', () async {
    await client.login(password);
    final task = (await client.feed('tracked')).groups.single.tasks.single;
    final original = await client.editor(task);
    expect(original.canEditSubtaskTitle(original.subtasks['2']!), isTrue);

    subtaskIds = [2, 1];
    await client.save(task, {}, subtaskTitles: {'2': '  核对答案  '});
    expect(written, containsPair('subitem_id[0]', '2'));
    expect(written, containsPair('subitem_title[0]', '核对答案'));
    expect(written, containsPair('subitem_due_date[0]', '2026-11-22'));
    expect(written, containsPair('subitem_due_time[0]', '15:00'));
    expect(written, containsPair('subitem_done[0]', '1'));
    expect(written.containsKey('subitem_completed_at[0]'), isFalse);
    expect(written, containsPair('subitem_title[1]', '子任务 1'));
  });

  test('blank, removed or newly read-only subtask titles are never submitted', () async {
    await client.login(password);
    final task = (await client.feed('tracked')).groups.single.tasks.single;
    await expectLater(client.save(task, {}, subtaskTitles: {'2': '  '}), throwsA(isA<TodoError>()));
    expect(written, isEmpty);

    editorDone = true;
    final completed = await client.editor(task);
    expect(completed.canEditSubtaskTitle(completed.subtasks['2']!), isFalse);
    await expectLater(client.save(task, {}, subtaskTitles: {'2': '核对答案'}), throwsA(isA<TodoError>()));
    expect(written, isEmpty);

    editorDone = false;
    subtaskIds = [1];
    await expectLater(client.save(task, {}, subtaskTitles: {'2': '核对答案'}), throwsA(isA<TodoError>()));
    expect(written, isEmpty);
  });

  test('completion uses the single occurrence or whole-task form as shown', () async {
    await client.login(password);
    final task = (await client.feed('tracked')).groups.single.tasks.single;
    for (final scope in ['occurrence', 'task']) {
      completedScope = scope;
      expect((await client.detail(task)).completedAt, '2026-11-21T16:08');
      await client.change(task, 'complete', extra: {
        'completed_at': '2026-11-21T16:45', 'scope': scope, 'date': '2026-11-21',
      });
      expect(written, containsPair('scope', scope));
      expect(written, containsPair('date', '2026-11-21'));
      expect(written, containsPair('completed_at', '2026-11-21T16:45'));
      expect(written, containsPair('done', '1'));
    }
    written = {};
    await expectLater(client.change(task, 'complete', extra: {
      'completed_at': '2026-11-21T16:45', 'scope': 'occurrence',
    }), throwsA(isA<TodoError>()));
    expect(written, isEmpty);
  });

  test('ordinary task edits preserve completion and explicit edits override it', () async {
    await client.login(password);
    final task = (await client.feed('tracked')).groups.single.tasks.single;
    editorDone = true;
    await client.save(task, {'title': '另一项'});
    expect(written.containsKey('completed_at'), isFalse);
    await client.save(task, {'completed_at': '2026-11-21T16:45'});
    expect(written, containsPair('completed_at', '2026-11-21T16:45'));
  });
  test('completed subtask parsing includes timestamp for both admin and guest', () {
    for (final admin in [true, false]) {
      final detail = TaskDetail(parse(home(admin, detail: true,
        subtasks: completedSubtask(11, admin: admin))));
      expect(detail.subtasks.single.title, '检查');
      expect(detail.subtasks.single.done, isTrue);
      expect(detail.subtasks.single.deadline, '已按时完成');
      expect(detail.subtasks.single.completedAt, '2026-11-21T16:08');
    }
  });

  test('subtask completion edits bind stable IDs and work under a completed parent', () async {
    await client.login(password);
    final task = (await client.feed('tracked')).groups.single.tasks.single;
    subtaskRows = completedSubtask(22, title: '另一项') +
        completedSubtask(11, parentDone: true);
    await client.change(task, 'subitem_done', index: 0, extra: {
      'subtask_id': '11', 'subtask_title': '检查', 'completed_at': '2026-11-21T16:45',
    });
    expect(written, containsPair('op', 'subitem_done'));
    expect(written, containsPair('subitem_id', '11'));
    expect(written, containsPair('task_id', '7'));
    expect(written, containsPair('done', '1'));
    expect(written, containsPair('completed_at', '2026-11-21T16:45'));
    expect(written.containsKey('subtask_id'), isFalse);
    expect(written.containsKey('subtask_title'), isFalse);
  });

  test('stale subtask completion edits never re-complete an undone or removed child', () async {
    await client.login(password);
    final task = (await client.feed('tracked')).groups.single.tasks.single;
    for (final rows in [completedSubtask(11, done: false), completedSubtask(22)]) {
      subtaskRows = rows;
      written = {};
      await expectLater(client.change(task, 'subitem_done', index: 0, extra: {
        'subtask_id': '11', 'subtask_title': '检查', 'completed_at': '2026-11-21T16:45',
      }), throwsA(isA<TodoError>()));
      expect(written, isEmpty);
    }
  });

  test('ordinary subtask status changes preserve the completion timestamp', () async {
    await client.login(password);
    final task = (await client.feed('tracked')).groups.single.tasks.single;
    subtaskRows = completedSubtask(11);
    await client.change(task, 'subitem_done', index: 0,
      extra: {'subtask_id': '11', 'subtask_title': '检查', 'done': '0'});
    expect(written, containsPair('done', '0'));
    expect(written.containsKey('completed_at'), isFalse);
  });

  test('task editor changes child completion by fresh ID without touching other stamps', () async {
    await client.login(password);
    final task = (await client.feed('tracked')).groups.single.tasks.single;
    final original = await client.editor(task);
    expect(original.subtasks['2']?.completedAt, '2026-11-21T16:08');
    expect(original.subtasks['2']?.done, isTrue);
    subtaskIds = [2, 1];
    await client.save(task, {'title': '其他标题'});
    expect(written.keys.any((key) => key.startsWith('subitem_completed_at[')), isFalse);
    await client.save(task, {}, subtaskCompletions: {'2': '2026-11-21T16:45'});
    expect(written, containsPair('subitem_completed_at[0]', '2026-11-21T16:45'));
    expect(written.containsKey('subitem_completed_at[1]'), isFalse);
    editorDone = true;
    await client.save(task, {}, subtaskCompletions: {'2': '2026-11-21T16:50'});
    expect(written, containsPair('subitem_completed_at[0]', '2026-11-21T16:50'));
    written = {};
    await expectLater(client.save(task, {'status': 'active'},
      subtaskCompletions: {'2': '2026-11-21T16:55'}), throwsA(isA<TodoError>()));
    expect(written, isEmpty);
    await client.save(task, {'status': 'active'});
    expect(written.keys.any((key) => key.startsWith('subitem_done[')), isFalse);
  });

  test('far tracked rows and the latest server countdown labels retain web order', () {
    final labels = ['不到1小时 · 12月31日 23:59', '3小时后 · 1月1日 02:00',
      '1天2小时后 · 1月2日 01:00'];
    final fixture = '<main class="tl-main__scroll">'
      '<span class="tl-fold__name">未设截止日与远期</span>'
      '${labels.map((label) => row.replaceFirst('11/21 14:00', label)
          .replaceFirst('<div class="tl-section-head__name">学习</div>', '')).join()}'
      '</main>';
    final feed = Feed(parse(fixture));
    expect(feed.groups.single.label, '未设截止日与远期');
    expect(feed.groups.single.tasks.map((task) => task.deadline), labels);
  });

}
