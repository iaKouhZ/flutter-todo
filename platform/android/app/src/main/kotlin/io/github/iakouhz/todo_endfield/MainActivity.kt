package io.github.iakouhz.todo_endfield

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val store = LedgerStore(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "todo_endfield/device")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "read" -> result.success(store.readForApp())
                        "server" -> {
                            store.setServer(call.arguments as String)
                            DeadlineWidget.settingsChanged(this)
                            result.success(null)
                        }
                        "password" -> {
                            store.setPassword(call.arguments as String?)
                            DeadlineWidget.settingsChanged(this)
                            result.success(null)
                        }
                        "refreshWidget" -> {
                            DeadlineWidget.enqueue(this)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    result.error("storage", "无法读取或保存本机设置。", null)
                }
            }
    }
}
