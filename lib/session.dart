import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'server.dart';

class DeviceStore {
  static const _channel = MethodChannel('todo_endfield/device');

  Future<Map<String, String>> read() async =>
      await _channel.invokeMapMethod<String, String>('read') ?? {};

  Future<void> server(String url) => _channel.invokeMethod<void>('server', url);

  Future<void> password(String? password) =>
      _channel.invokeMethod<void>('password', password);

  Future<void> refreshWidget() => _channel.invokeMethod<void>('refreshWidget');
}

class Session extends ChangeNotifier {
  Session({DeviceStore? device}) : _device = device ?? DeviceStore();

  final DeviceStore _device;
  TodoServer? server;
  Feed? feed;
  String tab = 'tracked';
  String category = '';
  String query = '';
  String? password;
  String? error;
  String? gate;
  bool initialized = false;
  bool busy = false;
  bool automaticRefresh = false;
  DateTime? _automaticRetryAfter;
  bool _disposed = false;
  bool admin = false;
  bool arrangingServer = false;

  void _clearView() {
    feed = null;
    admin = false;
    tab = 'tracked';
    category = '';
    query = '';
    gate = null;
    error = null;
    _automaticRetryAfter = null;
  }

  Future<void> initialize() async {
    try {
      final settings = await _device.read();
      final url = settings['url'];
      if (url != null) {
        server = TodoServer(serverAddress(url));
        password = settings['password'];
        await _connect();
      }
    } catch (e) {
      error = readableError(e);
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  Future<void> setServer(String value) async {
    final uri = serverAddress(value);
    if (server?.base != uri) {
      await _device.server(uri.toString());
      server?.close();
      server = TodoServer(uri);
      password = null;
      _clearView();
    }
    arrangingServer = false;
    await refresh();
  }

  void chooseServer() {
    if (busy) return;
    arrangingServer = !arrangingServer;
    notifyListeners();
  }

  Future<void> _rejectPassword() async {
    password = null;
    admin = false;
    feed = null;
    gate = '保存的密码已失效，服务器密码可能已更改。请输入当前密码。';
    server!.forgetSession();
    await _device.password(null);
  }

  Future<void> _connect() async {
    if (password case final saved?) {
      try {
        await server!.login(saved);
      } on PasswordRejected {
        await _rejectPassword();
        return;
      }
    }
    await _load();
    _scheduleWidget();
  }

  Future<Feed> _getFeed() => server!.feed(tab, category: category, query: query);

  Future<void> _load() async {
    try {
      final page = await _getFeed();
      if (!page.admin && password != null) {
        await _restore();
        feed = await _getFeed();
      } else {
        feed = page;
      }
      admin = feed!.admin;
      gate = null;
      error = null;
    } on LoginRequired {
      try {
        await _restore();
        feed = await _getFeed();
        admin = feed!.admin;
        gate = null;
        error = null;
      } on LoginRequired {
        feed = null;
        admin = false;
        gate ??= '服务器已关闭访客访问，请输入密码。';
      }
    }
  }

  Future<void> _restore() async {
    final saved = password;
    if (saved == null) throw const LoginRequired();
    try {
      await server!.login(saved);
      admin = true;
    } on PasswordRejected {
      await _rejectPassword();
      throw const LoginRequired();
    }
  }

  Future<void> refresh({
    String? nextTab, String? nextCategory, String? nextQuery, bool automatic = false,
  }) async {
    if (server == null || busy || _disposed) return;
    final retryAfter = _automaticRetryAfter;
    if (automatic && retryAfter != null && DateTime.now().isBefore(retryAfter)) return;
    final oldTab = tab;
    final oldCategory = category;
    final oldQuery = query;
    tab = nextTab ?? tab;
    category = nextCategory ?? category;
    query = nextQuery ?? query;
    busy = true;
    automaticRefresh = automatic;
    if (!automatic) error = null;
    notifyListeners();
    try {
      await _load();
      _automaticRetryAfter = null;
      if (!automatic && !_disposed) _scheduleWidget();
    } catch (e) {
      if (e is LoginThrottled) {
        _automaticRetryAfter = DateTime.now().add(Duration(seconds: e.retryAfterSeconds ?? 60));
      }
      tab = oldTab;
      category = oldCategory;
      query = oldQuery;
      if (!automatic) error = readableError(e);
    } finally {
      busy = false;
      automaticRefresh = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> signIn(String value) async {
    if (value.isEmpty) throw const TodoError('请输入密码。');
    await server!.login(value);
    await _device.password(value);
    password = value;
    admin = true;
    gate = null;
    await _load();
    _scheduleWidget();
    notifyListeners();
  }

  Future<void> signOut() async {
    await _device.password(null);
    password = null;
    server!.forgetSession();
    await refresh();
  }

  Future<void> visitAsGuest() async {
    gate = null;
    await refresh();
  }

  // Only retry a mutation when the server explicitly denied it before writing.
  Future<T> authorized<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on LoginRequired {
      try {
        await _restore();
        return await action();
      } on LoginRequired {
        admin = false;
        notifyListeners();
        rethrow;
      }
    }
  }

  Future<void> didWrite() async {
    _scheduleWidget();
    await refresh();
  }

  void _scheduleWidget() {
    unawaited(_device.refreshWidget().catchError((Object _) {}));
  }

  @override
  void dispose() {
    _disposed = true;
    server?.close();
    super.dispose();
  }
}

String readableError(Object error) {
  if (error is TodoError) return error.message;
  if (error is TimeoutException) return '连接超时，请检查服务器和网络。';
  if (error is HandshakeException) {
    return 'HTTPS 证书校验失败：${error.osError?.message ?? error.message}';
  }
  if (error is SocketException) {
    return '无法连接服务器：${error.osError?.message ?? error.message}';
  }
  if (error is HttpException) return 'HTTP 请求失败：${error.message}';
  if (error is FormatException) return '服务器响应格式错误：${error.message}';
  if (error is PlatformException) return error.message ?? '无法访问本机设置。';
  return '连接失败，请检查网络、服务器地址和 HTTPS 证书。';
}
