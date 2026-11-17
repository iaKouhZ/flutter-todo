import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:todo_endfield/server.dart';

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

String home(bool admin, {bool detail = false}) => '''
<div class="tl-brand"><span class="tl-brand__name">待办清单</span></div>
${admin ? '<form id="bulk-form"></form>' : ''}
<main class="tl-main__scroll">$row</main>
${detail ? '''
<aside id="detail"><h2 class="tl-detail__title">交作业</h2>
<p class="tl-detail__body">数学</p>
${admin ? '''
<form action="/todo/action/" method="post">
 <input name="_csrf" value="test-token"><input name="op" value="complete">
 <input name="scope" value="occurrence"><input name="date" value="2026-11-21">
 <input name="id" value="7"><input name="done" value="1">
</form>''' : ''}
</aside>''' : ''}
''';

void main() {
  late HttpServer http;
  late TodoServer client;
  late String password;
  late bool public;
  late int credentialVersion;
  late Map<String, String> written;

  setUp(() async {
    password = '旧 口令 +&';
    public = true;
    credentialVersion = 1;
    written = {};
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
      } else if (path != '/todo/index.php' && !path.startsWith('/todo/tracked/task/')) {
        response.statusCode = 404;
      } else if (!public && !admin) {
        response.redirect(Uri.parse('/todo/login.php'));
        return;
      } else {
        response.write(home(admin, detail: path.startsWith('/todo/tracked/task/')));
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
}
