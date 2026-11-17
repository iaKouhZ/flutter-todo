package io.github.iakouhz.todo_endfield

import org.jsoup.Jsoup
import org.junit.Assert.assertEquals
import org.junit.Test

class WidgetFeedTest {
    private fun row(id: Int, date: String, title: String, extras: String = "",
        tracked: Boolean = false, doneOccurrence: Boolean = false, doneTask: Boolean = false
    ) = """
        <div data-task-row data-task-id="$id" data-occur-date="$date"
             class="${if (doneOccurrence) "tl-row--done" else ""}">
          <span class="tl-row__title">$title</span>
          <span class="tl-status${if (doneTask) " tl-status--done" else ""}"></span>
          ${if (tracked) """<span class="tl-track-mark">追踪</span>""" else ""}
          <ul class="tl-row__subitems">$extras</ul>
        </div>
    """

    private fun child(title: String, label: String) =
        """<li><span>$title</span><span class="tl-row__subdue">$label</span></li>"""

    private fun doc(vararg rows: String) =
        Jsoup.parse("""<main class="tl-main__scroll">${rows.joinToString("")}</main>""")

    @Test
    fun ordersActualYearsAndKeepsEligibleChildrenOfCompletedOccurrences() {
        val previous = row(1, "2026-01-01", "去年同月日")
        val thisYear = row(2, "2026-12-31", "年末")
        val nextYear = row(3, "2027-01-01", "元旦")
        val tracked = row(4, "2026-12-31", "已完成的单次发生",
            child("元旦检查", "明天 · 1月1日 08:00"), tracked = true, doneOccurrence = true)
        assertEquals(
            listOf(WidgetRow("年末", "12/31"), WidgetRow("↳ 元旦检查", "2027-01-01 08:00"),
                WidgetRow("元旦", "2027-01-01")),
            WidgetFeed.rows(doc(previous, nextYear, thisYear), doc(tracked), "2026-12-31 09:00"),
        )
    }

    @Test
    fun usesOnlyTheTrackedWebListAndPreservesDistinctChildrenWithTheSameTitle() {
        val included = row(1, "", "母任务",
            child("检查", "T+2 · 1月2日") + child("检查", "T+2 · 1月2日") +
                child("不在网页近日列表", "昨天 · 12月30日"), tracked = true)
        val allOnly = row(2, "", "全部",
            child("不应显示", "今天 · 12月31日"), tracked = true)
        val untracked = row(3, "", "规划中", child("未追踪", "今天 · 12月31日"))
        val complete = row(4, "", "已完成",
            child("已完成", "今天 · 12月31日"), tracked = true, doneTask = true)
        val rows = WidgetFeed.rows(doc(allOnly), doc(included, untracked, complete), "2026-12-31 09:00")
        assertEquals(List(2) { WidgetRow("↳ 检查", "2027-01-02") }, rows)
    }
}
