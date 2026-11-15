package mextensionserver.impl

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MirrorRouteOptimizerTest {
    private fun listPref(
        key: String,
        values: List<String>,
        labels: List<String>,
        index: Int,
    ): Map<String, Any> =
        mapOf(
            "key" to key,
            "listPreference" to
                mapOf(
                    "valueIndex" to index,
                    "entries" to labels,
                    "entryValues" to values,
                ),
        )

    private fun candidates(vararg values: String): List<MirrorRouteOptimizer.Candidate> =
        values.map { MirrorRouteOptimizer.Candidate(it, "https://$it.example") }

    private fun result(
        value: String,
        elapsedMs: Long,
    ): MirrorRouteOptimizer.ProbeResult = MirrorRouteOptimizer.ProbeResult(value, elapsedMs)

    @Test
    fun entryValuesAreUrls() {
        val route =
            MirrorRouteOptimizer.extractRoute(
                listOf(
                    listPref(
                        "preferred_mirror",
                        listOf("https://a.example", "https://b.example"),
                        listOf("甲线路", "乙线路"),
                        0,
                    ),
                ),
            )!!
        assertEquals("preferred_mirror", route.key)
        assertEquals(0, route.currentIndex)
        assertEquals(2, route.candidates.size)
        assertEquals("https://a.example", route.candidates[0].probeUrl)
        assertEquals("https://a.example", route.candidates[0].writeValue)
    }

    @Test
    fun entryValuesAreIndicesAndLabelsHoldUrls() {
        val route =
            MirrorRouteOptimizer.extractRoute(
                listOf(
                    listPref(
                        "preferred_mirror",
                        listOf("0", "1", "2"),
                        listOf("线路一 www.a.example", "线路二 www.b.example", "线路三 www.c.example"),
                        1,
                    ),
                ),
            )!!
        assertEquals(1, route.currentIndex)
        assertEquals(3, route.candidates.size)
        // 写回的必须是编号，探测用的必须是网址。
        assertEquals("1", route.candidates[1].writeValue)
        assertEquals("https://www.b.example", route.candidates[1].probeUrl)
    }

    @Test
    fun oneCandidateIsIgnored() {
        assertNull(
            MirrorRouteOptimizer.extractRoute(
                listOf(listPref("k", listOf("https://a.example"), listOf("甲"), 0)),
            ),
        )
    }

    @Test
    fun ordinaryListPreferenceIsIgnored() {
        assertNull(
            MirrorRouteOptimizer.extractRoute(
                listOf(listPref("theme", listOf("0", "1"), listOf("浅色", "深色"), 0)),
            ),
        )
    }

    @Test
    fun choosePreferenceWithMostCandidates() {
        val route =
            MirrorRouteOptimizer.extractRoute(
                listOf(
                    listPref("small", listOf("https://a.example", "https://b.example"), listOf("甲", "乙"), 0),
                    listPref(
                        "large",
                        listOf("https://a.example", "https://b.example", "https://c.example"),
                        listOf("甲", "乙", "丙"),
                        0,
                    ),
                ),
            )!!
        assertEquals("large", route.key)
        assertEquals(3, route.candidates.size)
    }

    @Test
    fun cleanUrlNormalizes() {
        assertEquals("https://www.a.example", MirrorRouteOptimizer.cleanUrl("www.a.example"))
        assertEquals("https://www.a.example/path", MirrorRouteOptimizer.cleanUrl("https://www.a.example/path"))
        assertNull(MirrorRouteOptimizer.cleanUrl("5"))
        assertNull(MirrorRouteOptimizer.cleanUrl("浅色"))
        assertNull(MirrorRouteOptimizer.cleanUrl(""))
    }

    @Test
    fun badBodyMarkers() {
        assertTrue(MirrorRouteOptimizer.isBadBody("x".repeat(100) + "站点维护中"))
        assertTrue(MirrorRouteOptimizer.isBadBody("x".repeat(100) + "Just a moment..."))
        assertTrue(MirrorRouteOptimizer.isBadBody("x".repeat(100) + "cf-chl"))
        assertTrue(MirrorRouteOptimizer.isBadBody("too short"))
        assertFalse(MirrorRouteOptimizer.isBadBody("<html><body>" + "x".repeat(200) + "</body></html>"))
    }

    @Test
    fun winnerNeedsRealGain() {
        val list = candidates("a", "b")
        assertNull(
            MirrorRouteOptimizer.selectWinner(listOf(result("a", 1000), result("b", 900)), 0, list),
            "只快 100 毫秒，不该切换",
        )
        assertNull(
            MirrorRouteOptimizer.selectWinner(listOf(result("a", 1000), result("b", 810)), 0, list),
            "快了 19%，没到 20%，不该切换",
        )
        assertEquals(
            list[1],
            MirrorRouteOptimizer.selectWinner(listOf(result("a", 1000), result("b", 700)), 0, list),
        )
    }

    @Test
    fun allFailuresKeepCurrent() {
        assertNull(MirrorRouteOptimizer.selectWinner(emptyList(), 0, candidates("a", "b")))
    }

    @Test
    fun currentDownNeedsTwoSuccesses() {
        val list = candidates("a", "b", "c")
        assertNull(
            MirrorRouteOptimizer.selectWinner(listOf(result("b", 500)), 0, list),
            "当前线路没测通且只有一条其它线路成功，不该切换",
        )
        assertEquals(
            list[1],
            MirrorRouteOptimizer.selectWinner(listOf(result("b", 500), result("c", 600)), 0, list),
        )
    }

    @Test
    fun ttlAndBackoff() {
        assertEquals(6 * 60 * 60 * 1000L, MirrorRouteOptimizer.ttlFor(0))
        assertEquals(30 * 60 * 1000L, MirrorRouteOptimizer.ttlFor(1))
        assertEquals(60 * 60 * 1000L, MirrorRouteOptimizer.ttlFor(2))
        assertEquals(4 * 60 * 60 * 1000L, MirrorRouteOptimizer.ttlFor(9))
    }
}
