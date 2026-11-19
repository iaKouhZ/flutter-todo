package io.github.iakouhz.todo_endfield

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

class DeadlineWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        draw(context)
        schedulePeriodic(context)
        enqueue(context)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context, manager: AppWidgetManager, id: Int, options: Bundle,
    ) {
        draw(context)
    }

    override fun onDisabled(context: Context) {
        val work = WorkManager.getInstance(context)
        work.cancelUniqueWork(periodic)
        work.cancelUniqueWork(immediate)
    }

    companion object {
        private const val periodic = "ledger-widget-periodic"
        private const val immediate = "ledger-widget-refresh"
        private val connected = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED).build()

        private fun ids(context: Context) = AppWidgetManager.getInstance(context)
            .getAppWidgetIds(ComponentName(context, DeadlineWidget::class.java))

        internal fun hasWidgets(context: Context) = ids(context).isNotEmpty()

        internal fun settingsChanged(context: Context) {
            if (hasWidgets(context)) {
                draw(context)
                enqueue(context)
            }
        }

        internal fun enqueue(context: Context) {
            if (!hasWidgets(context)) return
            WorkManager.getInstance(context).enqueueUniqueWork(immediate,
                ExistingWorkPolicy.REPLACE,
                OneTimeWorkRequestBuilder<DeadlineWorker>()
                    .setConstraints(connected).build())
        }

        private fun schedulePeriodic(context: Context) {
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(periodic,
                ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequestBuilder<DeadlineWorker>(30, TimeUnit.MINUTES)
                    .setConstraints(connected).build())
        }

        internal fun draw(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val store = LedgerStore(context)
            val snapshot = store.snapshot()
            val views = RemoteViews(context.packageName, R.layout.deadline_widget)
            val launch = Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_MAIN)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            views.setOnClickPendingIntent(R.id.widget_header,
                PendingIntent.getActivity(context, 0, launch,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            val message = when {
                !store.hasServer() -> R.string.widget_setup
                snapshot.state == "login" -> R.string.widget_sign_in
                snapshot.state == "offline" -> R.string.widget_offline
                snapshot.state == "ready" -> R.string.widget_empty
                else -> R.string.widget_loading
            }
            val rows = if (message == R.string.widget_setup || message == R.string.widget_sign_in)
                emptyList() else snapshot.rows
            views.setTextViewText(R.id.widget_title, context.getString(
                if (rows.isNotEmpty() && snapshot.state == "offline") R.string.widget_stale
                else R.string.widget_title))
            views.setTextViewText(R.id.widget_status, context.getString(message))
            views.setViewVisibility(R.id.widget_status, if (rows.isEmpty()) View.VISIBLE else View.GONE)
            views.setEmptyView(R.id.widget_list, R.id.widget_status)
            views.setPendingIntentTemplate(R.id.widget_list,
                PendingIntent.getActivity(context, 1, launch,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE))
            val widgetIds = ids(context)
            for (id in widgetIds) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    val items = RemoteViews.RemoteCollectionItems.Builder()
                        .setViewTypeCount(1)
                        .setHasStableIds(false)
                    rows.forEachIndexed { index, row ->
                        items.addItem(index.toLong(), DeadlineWidgetService.rowViews(context, row))
                    }
                    views.setRemoteAdapter(R.id.widget_list, items.build())
                } else {
                    val adapter = Intent(context, DeadlineWidgetService::class.java)
                        .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                        .setData(Uri.parse("ledger-widget://list/$id"))
                    @Suppress("DEPRECATION")
                    views.setRemoteAdapter(R.id.widget_list, adapter)
                }
                manager.updateAppWidget(id, views)
            }
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && widgetIds.isNotEmpty()) {
                @Suppress("DEPRECATION")
                manager.notifyAppWidgetViewDataChanged(widgetIds, R.id.widget_list)
            }
        }
    }
}

class DeadlineWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        if (!DeadlineWidget.hasWidgets(applicationContext)) return Result.success()
        val store = LedgerStore(applicationContext)
        val settings = try {
            store.connection()
        } catch (_: Exception) {
            return Result.failure()
        }
        val url = settings.url ?: return Result.success()
        try {
            val rows = WidgetFeed(url).read(settings.password)
            if (isStopped) return Result.success()
            store.publish(settings.revision, if (rows == null) "login" else "ready", rows ?: emptyList())
        } catch (_: WidgetLoginThrottled) {
            // Keep cached tasks; the normal periodic update can try again later.
            return Result.success()
        } catch (_: Exception) {
            if (isStopped) return Result.success()
            store.publish(settings.revision, "offline")
            DeadlineWidget.draw(applicationContext)
            return if (runAttemptCount < 2) Result.retry() else Result.success()
        }
        DeadlineWidget.draw(applicationContext)
        return Result.success()
    }
}
