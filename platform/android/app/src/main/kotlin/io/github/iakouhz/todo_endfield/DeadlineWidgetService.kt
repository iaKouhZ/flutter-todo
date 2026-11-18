package io.github.iakouhz.todo_endfield

import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService

class DeadlineWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory = Factory(applicationContext)

    private class Factory(private val context: Context) : RemoteViewsFactory {
        private var rows = emptyList<WidgetRow>()

        override fun onCreate() = Unit

        override fun onDataSetChanged() {
            val store = LedgerStore(context)
            val snapshot = store.snapshot()
            rows = if (!store.hasServer() || snapshot.state == "login") emptyList() else snapshot.rows
        }

        override fun onDestroy() {
            rows = emptyList()
        }

        override fun getCount() = rows.size
        override fun getViewTypeCount() = 1
        override fun hasStableIds() = false
        override fun getItemId(position: Int) = position.toLong()
        override fun getLoadingView(): RemoteViews? = null
        override fun getViewAt(position: Int): RemoteViews? =
            rows.getOrNull(position)?.let { rowViews(context, it) }
    }

    companion object {
        internal fun rowViews(context: Context, row: WidgetRow): RemoteViews {
            val child = row.title.startsWith("↳ ")
            val views = RemoteViews(context.packageName, R.layout.deadline_widget_row)
            val inset = if (child) (8 * context.resources.displayMetrics.density).toInt() else 0
            views.setViewPadding(R.id.widget_row_title, inset, 0, 0, 0)
            views.setTextViewText(R.id.widget_row_title, row.title)
            views.setTextViewText(R.id.widget_row_deadline, row.deadline.replace(' ', '\n'))
            views.setViewVisibility(R.id.widget_row_deadline,
                if (row.deadline.isEmpty()) View.GONE else View.VISIBLE)
            views.setOnClickFillInIntent(R.id.widget_row, Intent())
            return views
        }
    }
}
