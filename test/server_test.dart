import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

String home(bool admin, {bool detail = false, String? completedScope}) => '''
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
 <input name="subitem_title[$index]" value="子任务 $id">
 <input type="date" name="subitem_due_date[$index]" value="2026-11-2$id">
 <input type="time" name="subitem_due_time[$index]" value="15:00">
 ${id == 2 ? '<input type="checkbox" name="subitem_done[$index]" value="1" checked>' : ''}
 ''';
 }).join()}
</form>''';

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

  setUp(() async {
    password = '旧 口令 +&';
    public = true;
    credentialVersion = 1;
    written = {};
    completedScope = null;
    subtaskIds = [1, 2];
    editorDone = false;
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
          completedScope: completedScope));
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

  test('guest reads a public server but cannot change it', () async {
    final feed = await client.feed('tracked');
    expect(feed.admin, isFalse);
    final task = feed.groups.single.tasks.single;
    expect(task.title, '交作业');
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
}
