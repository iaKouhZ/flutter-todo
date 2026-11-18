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
            listOf(WidgetRow("年末", "12/31"), WidgetRow("已完成的单次发生", ""),
                WidgetRow("↳ 元旦检查", "2027-01-01 08:00"), WidgetRow("元旦", "2027-01-01"),
                WidgetRow("去年同月日", "01/01")),
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
        assertEquals(listOf(WidgetRow("母任务", "")) +
            List(2) { WidgetRow("↳ 检查", "2027-01-02") }, rows)
    }

    @Test
    fun putsTheDatedParentBeforeItsChildrenEvenWhenItIsDueLater() {
        val parent = row(1, "2027-01-18", "微积分 A(I)")
        val tracked = row(1, "2027-01-18", "微积分 A(I)",
            child("微分中值定理", "T+2 · 1月2日") +
                child("洛必达法则", "今天 · 12月31日 13:30") +
                child("同日更晚", "今天 · 12月31日 16:00"), tracked = true)
        val unrelated = row(2, "2027-01-01", "其他主任务")
        assertEquals(
            listOf(WidgetRow("微积分 A(I)", "2027-01-18"),
                WidgetRow("↳ 洛必达法则", "12/31 13:30"), WidgetRow("↳ 同日更晚", "12/31 16:00"),
                WidgetRow("↳ 微分中值定理", "2027-01-02"), WidgetRow("其他主任务", "2027-01-01")),
            WidgetFeed.rows(doc(parent, unrelated), doc(tracked), "2026-12-31 09:00"),
        )
    }

    @Test
    fun keepsUndatedParentsAndChildrenBeyondTheFirstThreeRows() {
        val first = row(1, "2026-12-31", "第一项")
        val second = row(2, "2027-01-01", "第二项")
        val third = row(3, "2027-01-04", "第三项")
        val undated = row(4, "", "无截止主任务",
            child("检查", "T+2 · 1月2日"), tracked = true)
        assertEquals(
            listOf("第一项", "第二项", "无截止主任务", "↳ 检查", "第三项"),
            WidgetFeed.rows(doc(third, first, second), doc(undated), "2026-12-31 09:00")
                .map { it.title },
        )
    }

    @Test
    fun keepsAllRowsForScrollingAndGroupsEveryChildBelowItsParent() {
        val children = (1..12).reversed().joinToString("") {
            child("子任务 $it", "T+$it · 1月${it}日")
        }
        val parent = row(1, "2027-01-18", "长期任务", children, tracked = true)
        val others = (2..15).map { row(it, "2027-02-01", "任务 $it") }
        val rows = WidgetFeed.rows(doc(parent, *others.toTypedArray()), doc(parent), "2026-12-31 09:00")
        assertEquals(27, rows.size)
        assertEquals("长期任务", rows.first().title)
        assertEquals((1..12).map { "↳ 子任务 $it" }, rows.subList(1, 13).map { it.title })
        assertEquals("任务 15", rows.last().title)
    }
}
