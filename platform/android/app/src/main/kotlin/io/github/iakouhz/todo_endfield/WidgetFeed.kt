package io.github.iakouhz.todo_endfield

import org.jsoup.Connection
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import java.net.URI
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** The widget reads the server-rendered list using its own short-lived session. */
internal class WidgetFeed(server: String) {
    private val base = URI(server)
    private val session = Jsoup.newSession()
        .userAgent("Todo Endfield Android widget")
        .timeout(12_000)
        .maxBodySize(12 * 1024 * 1024)
        .followRedirects(false)
        .ignoreHttpErrors(true)

    private fun request(start: URI, fields: Map<String, String>? = null): Connection.Response {
        var next = start
        var form = fields
        repeat(6) {
            require(next.scheme == base.scheme && next.host.equals(base.host, ignoreCase = true)
                && effectivePort(next) == effectivePort(base) && next.userInfo == null)
            val request = session.newRequest().url(next.toURL())
            val body = form
            if (body != null) request.method(Connection.Method.POST).data(body)
            val response = request.execute()
            val location = response.header("Location")
            if (location == null || response.statusCode() !in listOf(301, 302, 303, 307, 308)) {
                return response
            }
            require(body == null || response.statusCode() !in listOf(307, 308))
            next = next.resolve(location)
            form = null
        }
        error("Too many redirects")
    }

    private fun effectivePort(uri: URI): Int = when {
        uri.port != -1 -> uri.port
        uri.scheme == "https" -> 443
        else -> 80
    }

    private fun login(password: String): Boolean {
        val response = request(base.resolve("login.php"))
        val page = response.parse()
        val form = checkNotNull(page.selectFirst("form.tl-gate__form"))
        val csrf = checkNotNull(form.selectFirst("input[name=_csrf]")).attr("value")
        val back = form.selectFirst("input[name=back]")?.attr("value").orEmpty()
        val result = request(response.url().toURI().resolve(form.attr("action")),
            mapOf("_csrf" to csrf, "back" to back, "password" to password))
        val document = result.parse()
        if (document.selectFirst(".tl-gate__error") != null || result.statusCode() in listOf(401, 403)) {
            return false
        }
        check(result.statusCode() == 200 && document.selectFirst("#bulk-form") != null)
        return true
    }

    private fun list(tab: String): Document? {
        val result = request(base.resolve("index.php?tab=$tab"))
        if (result.statusCode() in listOf(401, 403)) return null
        check(result.statusCode() == 200)
        val doc = result.parse()
        if (doc.selectFirst(".tl-gate__form") != null) return null
        check(doc.selectFirst(".tl-main__scroll") != null)
        return doc
    }

    private data class Deadline(val id: String, val title: String, val date: String,
        val time: String, val overdue: Boolean) {
        val key = "$date ${time.ifEmpty { "23:59" }}"
        fun label() = date.substring(5).replace('-', '/') +
            (if (time.isEmpty()) "" else " $time") + "  ·  " + title
    }

    private fun deadlines(doc: Document, now: String): List<Deadline> = doc
        .select(".tl-main__scroll [data-task-row]:not(.tl-row--done)")
        .mapNotNull { row ->
            val id = row.attr("data-task-id")
            val date = row.attr("data-occur-date")
            val title = row.selectFirst(".tl-row__title")?.text().orEmpty()
            val due = row.selectFirst(".tl-row__deadline")?.text().orEmpty()
            val time = timeAtEnd.find(due)?.value.orEmpty()
            if (id.isBlank() || title.isBlank() || !dateFormat.matches(date)) return@mapNotNull null
            Deadline(id, title, date, time, row.hasClass("tl-row--overdue") ||
                "$date ${time.ifEmpty { "23:59" }}" < now)
        }

    fun read(password: String?): List<String>? {
        if (password != null && !login(password)) return null
        val all = list("all") ?: return null
        if (password != null && all.selectFirst("#bulk-form") == null) return null
        val clock = all.selectFirst("[data-clock]")
        val zone = clock?.attr("data-tz")?.takeIf { it.isNotBlank() } ?: "Asia/Shanghai"
        val epoch = clock?.attr("data-epoch")?.toLongOrNull() ?: System.currentTimeMillis()
        val now = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).apply {
            timeZone = TimeZone.getTimeZone(zone)
        }.format(Date(epoch))
        val tracked = list("tracked") ?: return null
        val tasks = deadlines(all, now) + deadlines(tracked, now)
        // Prefer upcoming items and then show the most recently overdue ones.
        val upcoming = tasks.filterNot { it.overdue }.sortedBy { it.key }
        val overdue = tasks.filter { it.overdue }.sortedByDescending { it.key }
        return (upcoming + overdue).distinctBy { it.id }.take(3).map { it.label() }
    }

    private companion object {
        val dateFormat = Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}")
        val timeAtEnd = Regex("[0-9]{2}:[0-9]{2}$")
    }
}
