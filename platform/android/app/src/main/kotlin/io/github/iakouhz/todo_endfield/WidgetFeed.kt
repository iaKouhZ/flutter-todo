package io.github.iakouhz.todo_endfield

import org.jsoup.Connection
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import java.net.URI
import java.text.SimpleDateFormat
import java.util.Date
import kotlin.math.abs
import java.util.Locale
import java.util.TimeZone

internal class WidgetLoginThrottled : Exception()

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
        if (response.statusCode() == 429) throw WidgetLoginThrottled()
        val page = response.parse()
        val form = checkNotNull(page.selectFirst("form.tl-gate__form"))
        val csrf = checkNotNull(form.selectFirst("input[name=_csrf]")).attr("value")
        val back = form.selectFirst("input[name=back]")?.attr("value").orEmpty()
        val result = request(response.url().toURI().resolve(form.attr("action")),
            mapOf("_csrf" to csrf, "back" to back, "password" to password))
        if (result.statusCode() == 429) throw WidgetLoginThrottled()
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

    fun read(password: String?): List<WidgetRow>? {
        if (password != null && !login(password)) return null
        val all = list("all") ?: return null
        val tracked = list("tracked") ?: return null
        if (password != null &&
            (all.selectFirst("#bulk-form") == null || tracked.selectFirst("#bulk-form") == null)
        ) return null
        return rows(all, tracked, serverNow(tracked))
    }

    private data class Deadline(val id: String, val title: String, val date: String,
        val time: String, val overdue: Boolean) {
        val key = "$date ${time.ifEmpty { "23:59" }}"

        fun display(year: String): WidgetRow {
            val displayDate = if (date.startsWith("$year-")) {
                date.substring(5).replace('-', '/')
            } else {
                date
            }
            return WidgetRow(title, if (time.isEmpty()) displayDate else "$displayDate $time")
        }
    }

    private data class SubtaskGroup(val title: String, val deadlines: List<Deadline>)

    companion object {
        private val isoDate = Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}")
        private val timeAtEnd = Regex("[0-9]{2}:[0-9]{2}$")
        private val subtaskLabel = Regex(
            "(今天|明天|T\\+[0-9]+|不到1小时|[0-9]+小时后|[0-9]+天[0-9]+小时后)" +
                "\\s*·\\s*([0-9]+)月([0-9]+)日(?:\\s+([0-9]{2}:[0-9]{2}))?")
        private val remainingHours = Regex("(?:([0-9]+)天)?([0-9]+)小时后")
        private const val rowSelector = ".tl-main__scroll [data-task-row]"

        private fun serverNow(doc: Document): String {
            val clock = doc.selectFirst("[data-clock]")
            val zone = clock?.attr("data-tz")?.takeIf { it.isNotBlank() } ?: "Asia/Shanghai"
            val epoch = clock?.attr("data-epoch")?.toLongOrNull() ?: System.currentTimeMillis()
            val now = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).apply {
                timeZone = TimeZone.getTimeZone(zone)
            }.format(Date(epoch))
            val day = clock?.attr("data-day")?.takeIf(isoDate::matches) ?: now.substring(0, 10)
            val time = clock?.selectFirst("[data-clock-time]")?.attr("datetime")
                ?.takeIf(timeAtEnd::matches) ?: now.substring(11)
            return "$day $time"
        }

        private fun tasks(doc: Document, now: String): List<Deadline> = doc
            .select("$rowSelector:not(.tl-row--done)")
            .mapNotNull { row ->
                val id = row.attr("data-task-id")
                val date = row.attr("data-occur-date")
                val title = row.selectFirst(".tl-row__title")?.text().orEmpty()
                val due = row.selectFirst(".tl-row__deadline")?.text().orEmpty()
                val time = timeAtEnd.find(due)?.value.orEmpty()
                if (id.isBlank() || title.isBlank() || !isoDate.matches(date)) return@mapNotNull null
                Deadline(id, title, date, time, row.hasClass("tl-row--overdue") ||
                    "$date ${time.ifEmpty { "23:59" }}" < now)
            }

        private fun subtasks(doc: Document, now: String): Map<String, SubtaskGroup> {
            val calendarDate = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
                isLenient = false
            }
            val today = calendarDate.parse(now.substring(0, 10)) ?: return emptyMap()
            val groups = linkedMapOf<String, SubtaskGroup>()
            for (row in doc.select(rowSelector)) {
                val id = row.attr("data-task-id")
                val parentTitle = row.selectFirst(".tl-row__title")?.text().orEmpty()
                if (id.isBlank() || parentTitle.isBlank() || id in groups ||
                    row.selectFirst(".tl-track-mark") == null ||
                    row.selectFirst(".tl-status--done") != null
                ) continue
                // Only the server's near-term list has these rows. A completed
                // occurrence can carry children while its series is still active.
                val deadlines = row.select(".tl-row__subitems > li").mapNotNull { item ->
                    val title = item.selectFirst("span:first-child")?.text().orEmpty()
                    val label = item.selectFirst(".tl-row__subdue")?.text().orEmpty()
                    val match = subtaskLabel.matchEntire(label) ?: return@mapNotNull null
                    val date = childDate(match, now, today, calendarDate) ?: return@mapNotNull null
                    if (title.isBlank()) return@mapNotNull null
                    val time = match.groupValues[4]
                    Deadline(id, "↳ $title", date, time,
                        "$date ${time.ifEmpty { "23:59" }}" < now)
                }
                if (deadlines.isNotEmpty()) groups[id] = SubtaskGroup(parentTitle, deadlines)
            }
            return groups
        }

        // Resolve the year from the server's relative hours and calendar label.
        // A label such as "不到1小时 · 1月1日 00:15" can cross midnight/year
        // even though it contains no whole day. Do not treat rounded hours as days.
        private fun childDate(match: MatchResult, now: String, today: Date,
            calendarDate: SimpleDateFormat): String? {
            val label = match.groupValues[1]
            val month = match.groupValues[2].toIntOrNull() ?: return null
            val day = match.groupValues[3].toIntOrNull() ?: return null
            fun matches(date: String) = isoDate.matches(date) &&
                date.substring(5, 7).toInt() == month && date.substring(8, 10).toInt() == day
            val legacyDays = when {
                label == "今天" -> 0L
                label == "明天" -> 1L
                label.startsWith("T+") -> label.substring(2).toLongOrNull()
                else -> null
            }
            if (legacyDays != null) {
                if (legacyDays !in 0..365000L) return null
                return calendarDate.format(Date(today.time + legacyDays * 86_400_000L))
                    .takeIf(::matches)
            }
            val hours = if (label == "不到1小时") 0L else {
                val remaining = remainingHours.matchEntire(label) ?: return null
                val days = remaining.groupValues[1].ifEmpty { "0" }.toLongOrNull() ?: return null
                val part = remaining.groupValues[2].toLongOrNull() ?: return null
                if (days !in 0..365000L || part !in 0..23L && remaining.groupValues[1].isNotEmpty())
                    return null
                days * 24 + part
            }
            if (hours !in 0..8_760_000L) return null
            val clock = now.substring(11).split(':')
            val current = today.time + clock[0].toLong() * 3_600_000L + clock[1].toLong() * 60_000L
            val estimate = current + hours * 3_600_000L
            val year = calendarDate.format(Date(estimate)).substring(0, 4).toInt()
            val time = match.groupValues[4].ifEmpty { "23:59" }.split(':')
            val hour = time[0].toIntOrNull() ?: return null
            val minute = time[1].toIntOrNull() ?: return null
            if (hour !in 0..23 || minute !in 0..59) return null
            return (year - 1..year + 1).mapNotNull { candidateYear ->
                val date = String.format(Locale.US, "%04d-%02d-%02d", candidateYear, month, day)
                val parsed = try { calendarDate.parse(date) } catch (_: Exception) { null }
                    ?: return@mapNotNull null
                if (!matches(date)) return@mapNotNull null
                date to abs(parsed.time + hour * 3_600_000L + minute * 60_000L - estimate)
            }.minByOrNull { it.second }?.first
        }

        private fun nearestFirst(candidates: List<Deadline>): List<Deadline> {
            val upcoming = candidates.filterNot { it.overdue }.sortedBy { it.key }
            val overdue = candidates.filter { it.overdue }.sortedByDescending { it.key }
            return upcoming + overdue
        }

        internal fun rows(all: Document, tracked: Document, now: String): List<WidgetRow> {
            val parents = nearestFirst(tasks(all, now) + tasks(tracked, now))
                .distinctBy { it.id }.associateBy { it.id }
            val children = subtasks(tracked, now)
            val groups = nearestFirst(parents.values + children.values.flatMap { it.deadlines })
                .distinctBy { it.id }
            val year = now.substring(0, 4)
            return buildList {
                for (group in groups) {
                    val parent = parents[group.id]
                    val subtasks = children[group.id]
                    if (parent == null) {
                        if (subtasks == null) continue
                        add(WidgetRow(subtasks.title, ""))
                    } else {
                        add(parent.display(year))
                    }
                    subtasks?.deadlines?.sortedBy { it.key }?.forEach {
                        add(it.display(year))
                    }
                }
            }
        }
    }
}
