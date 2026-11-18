import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'session.dart';

class DesktopSettingsScreen extends StatefulWidget {
  const DesktopSettingsScreen({super.key});

  @override
  State<DesktopSettingsScreen> createState() => _DesktopSettingsScreenState();
}

class _DesktopSettingsScreenState extends State<DesktopSettingsScreen> {
  static const channel = MethodChannel('todo_endfield/device');
  bool startup = false;
  bool topmost = false;
  bool busy = true;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final values = await channel.invokeMapMethod<String, bool>('desktopRead') ?? {};
      if (!mounted) return;
      setState(() {
        startup = values['startup'] ?? false;
        topmost = values['topmost'] ?? false;
        busy = false;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() { busy = false; error = readableError(e); });
    }
  }

  Future<void> update(String method, bool value) async {
    setState(() { busy = true; error = null; });
    try {
      await channel.invokeMethod<void>(method, value);
      await load();
    } catch (e) {
      if (mounted) setState(() { busy = false; error = readableError(e); });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('电脑版设置')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(padding: const EdgeInsets.all(20), children: [
          SwitchListTile(
            title: const Text('自启动'),
            subtitle: const Text('登录 Windows 后启动应用'),
            value: startup,
            onChanged: busy ? null : (v) => update('desktopSetStartup', v),
          ),
          SwitchListTile(
            title: const Text('窗口置顶'),
            subtitle: const Text('保持在其他普通窗口上方'),
            value: topmost,
            onChanged: busy ? null : (v) => update('desktopSetTopmost', v),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null) ...[
            Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            TextButton(onPressed: busy ? null : load, child: const Text('重试')),
          ],
        ]),
      ),
    ),
  );
}
