package mextensionserver.impl

import android.app.Application
import eu.kanade.tachiyomi.animesource.AnimeSource
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.source.Source
import io.github.oshai.kotlinlogging.KotlinLogging
import mextensionserver.model.DataBody
import okhttp3.OkHttpClient
import okhttp3.Request
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get
import java.net.URI
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorCompletionService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * 按需、并行、全局的线路优选服务。
 *
 * 触发时机：某个源第一次被真正使用时，才在后台探测一次；主请求不等结果，照常按当前线路返回。
 * 候选线路直接来自宿主随每次请求下发的偏好快照（listPreference），所以不写死任何源，
 * 新安装的源首次使用就自动纳入。探测复用 NetworkHelper.client，与界面请求共用同一套
 * cookieJar、CloudflareInterceptor 和宿主 ProxySelector，不是被证伪的外部裸连。
 *
 * 三条安全边界：
 * 1. 只有探测成功、且比当前线路明显更快时才写回偏好；全部失败就保持现状，不会把页面弄坏。
 * 2. 只改运行时的 JVM 偏好 store，不碰宿主定稿的线路清单文件，也不改 APK 里写死的数组。
 * 3. 加启动参数 -Dfushi.mirrorOptimizer.enabled=false 可以一键关闭本服务。
 */
internal object MirrorRouteOptimizer {
    private val logger = KotlinLogging.logger {}

    /** 单条探测超时。本机 329 条真实响应 p90 约 2.7 秒、p99 约 5.4 秒，6 秒才不会误杀慢线路。 */
    internal const val PROBE_TIMEOUT_MS = 6_000L

    /** 整批窗口。窗口内没返回的候选算失败；慢线路本来也不会被选中，所以不影响择优。 */
    internal const val BATCH_WINDOW_MS = 12_000L

    internal const val CONCURRENCY = 6
    internal const val CACHE_TTL_MS = 6 * 60 * 60 * 1000L
    internal const val MIN_GAIN_MS = 200L
    internal const val GAIN_RATIO = 0.8
    internal const val PEEK_BYTES = 8_192L

    private val probePool =
        Executors.newFixedThreadPool(CONCURRENCY) { runnable ->
            Thread(runnable, "fushi-mirror-probe").apply { isDaemon = true }
        }

    // 调度线程与探测线程分开，避免调度任务占满探测池后互相等待。
    private val dispatchPool =
        Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "fushi-mirror-dispatch").apply { isDaemon = true }
        }

    private class SourceState {
        @Volatile
        var lastProbeAt: Long = 0L

        @Volatile
        var inFlight: Boolean = false

        @Volatile
        var consecutiveFailures: Int = 0
    }

    private val states = ConcurrentHashMap<String, SourceState>()

    /** 写回偏好用的是 writeValue，探测用的是 probeUrl，两者可能不同（编号 vs 网址）。 */
    internal data class Candidate(
        val writeValue: String,
        val probeUrl: String,
    )

    internal data class RoutePreference(
        val key: String,
        val currentIndex: Int,
        val candidates: List<Candidate>,
    )

    internal data class ProbeResult(
        val writeValue: String,
        val elapsedMs: Long,
    )

    private val URL_PATTERN = Regex("(?i)https?://[^\\s\"'<>)，,]+")
    private val HOST_PATTERN = Regex("(?i)(?:[a-z0-9-]+\\.)+[a-z]{2,}")

    private val BAD_MARKERS =
        listOf(
            "站点维护中",
            "即将跳转到导航页面",
            "请点击继续访问",
            "请直接访问",
            "just a moment",
            "checking your browser",
            "cf-chl",
            "cloudflare challenge",
            "enable javascript and cookies",
            "access denied",
            "403 forbidden",
            "502 bad gateway",
            "service unavailable",
        )

    private fun enabled(): Boolean = System.getProperty("fushi.mirrorOptimizer.enabled") != "false"

    /** 请求入口。这里必须吞掉所有异常，绝不能影响主请求。 */
    fun onRequest(
        data: DataBody,
        source: Any,
    ) {
        if (!enabled()) return
        // 用户正在手动改偏好时不抢状态。
        if (data.method.startsWith("setPreference")) return
        val sourceId = idOf(source) ?: return
        val route = extractRoute(data.preferences) ?: return
        try {
            val state = states.computeIfAbsent(sourceId) { SourceState() }
            val now = System.currentTimeMillis()
            val shouldRun =
                synchronized(state) {
                    if (state.inFlight || now - state.lastProbeAt < ttlFor(state.consecutiveFailures)) {
                        false
                    } else {
                        state.inFlight = true
                        state.lastProbeAt = now
                        true
                    }
                }
            if (!shouldRun) return
            // 显式写成 Runnable，避免 submit 的 Callable / Runnable 两个重载产生歧义。
            dispatchPool.submit(Runnable { runProbe(sourceId, route, state) })
        } catch (error: Throwable) {
            logger.warn(error) { "[Fushi][mirror-optimizer] 触发探测失败，已忽略" }
        }
    }

    private fun idOf(source: Any): String? =
        when (source) {
            is Source -> source.id.toString()
            is AnimeSource -> source.id.toString()
            else -> null
        }

    /** 连续失败时缩短重试间隔，但最多退避到 4 小时，且不超过正常缓存时长。 */
    internal fun ttlFor(consecutiveFailures: Int): Long {
        if (consecutiveFailures <= 0) return CACHE_TTL_MS
        val shift = minOf(consecutiveFailures - 1, 3)
        return minOf(CACHE_TTL_MS, 30 * 60 * 1000L * (1L shl shift))
    }

    /**
     * 从宿主偏好快照里找出「线路清单」那一项。
     *
     * 两种格式都要认：有的源 entryValues 就是网址；有的源 entryValues 只是编号，
     * 网址写在 entries 的显示名里。只有至少两个候选能解析出网址时，才认为它是线路偏好。
     * 一个源若有多项 listPreference，取候选最多的那一项。
     */
    internal fun extractRoute(preferences: List<Map<String, Any>>?): RoutePreference? {
        if (preferences == null) return null
        var best: RoutePreference? = null
        for (preference in preferences) {
            val key = preference["key"] as? String ?: continue
            val list = preference["listPreference"] as? Map<*, *> ?: continue
            val values =
                (list["entryValues"] as? List<*>)?.mapNotNull { it?.toString() } ?: continue
            val labels =
                (list["entries"] as? List<*>)?.map { it?.toString().orEmpty() } ?: emptyList()
            if (values.size < 2) continue
            val currentIndex = (list["valueIndex"] as? Number)?.toInt() ?: -1
            val candidates =
                values.indices.mapNotNull { index ->
                    val raw = values[index]
                    val url = cleanUrl(raw) ?: cleanUrl(labels.getOrElse(index) { "" })
                    if (url == null) return@mapNotNull null
                    Candidate(raw, url)
                }
            if (candidates.size < 2) continue
            val current = best
            if (current == null || candidates.size > current.candidates.size) {
                best = RoutePreference(key, currentIndex, candidates)
            }
        }
        return best
    }

    /** 把偏好值或显示名规范化成可请求的 URL；纯编号、纯文字一律返回 null。 */
    internal fun cleanUrl(raw: String): String? {
        val text = raw.trim()
        if (text.isEmpty()) return null
        val found =
            URL_PATTERN.find(text)?.value
                ?: HOST_PATTERN.find(text)?.value
                ?: return null
        val withScheme =
            if (found.startsWith("http://", ignoreCase = true) ||
                found.startsWith("https://", ignoreCase = true)
            ) {
                found
            } else {
                "https://$found"
            }
        val cleaned = withScheme.trimEnd(',', ';', ')', ']', '}', '"', '\'', '.')
        val host =
            try {
                URI(cleaned).host
            } catch (error: Exception) {
                null
            } ?: return null
        if (!host.contains('.') || host.any { it.isWhitespace() }) return null
        return cleaned
    }

    /** 维护页、跳转板和 CF 验证页都返回 200，必须按内容排除，否则会把页面弄坏。 */
    internal fun isBadBody(prefix: String): Boolean {
        if (prefix.length < 64) return true
        val lower = prefix.lowercase()
        return BAD_MARKERS.any { lower.contains(it) }
    }

    /**
     * 只有明显更快才允许切换：比当前快 20% 以上，且至少快 200 毫秒。
     * 当前线路没测通时，要求至少两条其它线路成功才换，避免一次抖动就误切。
     * 全部失败时 results 为空，返回 null，保持现状。
     */
    internal fun selectWinner(
        results: List<ProbeResult>,
        currentIndex: Int,
        candidates: List<Candidate>,
    ): Candidate? {
        if (results.isEmpty()) return null
        val currentValue = candidates.getOrNull(currentIndex)?.writeValue
        val currentMs = results.firstOrNull { it.writeValue == currentValue }?.elapsedMs
        val fastest = results.minByOrNull { it.elapsedMs } ?: return null
        val winner = candidates.firstOrNull { it.writeValue == fastest.writeValue } ?: return null
        if (winner.writeValue == currentValue) return null
        if (currentMs != null) {
            if (fastest.elapsedMs.toDouble() > currentMs * GAIN_RATIO) return null
            if (currentMs - fastest.elapsedMs < MIN_GAIN_MS) return null
        } else if (results.size < 2) {
            return null
        }
        return winner
    }

    private fun runProbe(
        sourceId: String,
        route: RoutePreference,
        state: SourceState,
    ) {
        try {
            val helper: NetworkHelper = Injekt.get()
            val app: Application = Injekt.get()
            // newBuilder 共享连接池与 dispatcher，只改超时，不会另起一套网络栈。
            val probeClient =
                helper.client
                    .newBuilder()
                    .callTimeout(PROBE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                    .build()
            val completion = ExecutorCompletionService<ProbeResult>(probePool)
            val tasks =
                route.candidates.map { candidate ->
                    completion.submit(Callable { probeOne(probeClient, candidate) })
                }
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(BATCH_WINDOW_MS)
            val results = mutableListOf<ProbeResult>()
            var pending = tasks.size
            while (pending > 0) {
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0L) break
                val future = completion.poll(remaining, TimeUnit.NANOSECONDS) ?: break
                pending--
                try {
                    results.add(future.get())
                } catch (error: Exception) {
                    logger.debug { "[Fushi][mirror-optimizer] 候选探测失败：${error.message}" }
                }
            }
            tasks.forEach { it.cancel(true) }

            val winner = selectWinner(results, route.currentIndex, route.candidates)
            if (winner != null) {
                val prefs = app.getSharedPreferences("source_$sourceId", 0)
                prefs.edit().putString(route.key, winner.writeValue).commit()
                logger.info {
                    "[Fushi][mirror-optimizer] $sourceId ${route.key} 切到 ${winner.probeUrl}" +
                        "（成功 ${results.size}/${route.candidates.size}）"
                }
            } else {
                logger.info {
                    "[Fushi][mirror-optimizer] $sourceId ${route.key} 保持当前线路" +
                        "（成功 ${results.size}/${route.candidates.size}）"
                }
            }
            synchronized(state) {
                state.consecutiveFailures =
                    if (results.isEmpty()) minOf(state.consecutiveFailures + 1, 4) else 0
            }
        } catch (error: Throwable) {
            logger.warn(error) { "[Fushi][mirror-optimizer] 探测异常，保持当前线路" }
            synchronized(state) {
                state.consecutiveFailures = minOf(state.consecutiveFailures + 1, 4)
            }
        } finally {
            synchronized(state) { state.inFlight = false }
        }
    }

    /** Range 头加只读前 8KB，避免为了测速把整页下载下来。 */
    private fun probeOne(
        client: OkHttpClient,
        candidate: Candidate,
    ): ProbeResult {
        val request =
            Request.Builder()
                .url(candidate.probeUrl)
                .header("Range", "bytes=0-8191")
                .header("Accept", "text/html,application/xhtml+xml,*/*;q=0.8")
                .get()
                .build()
        val start = System.nanoTime()
        return client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw IllegalStateException("HTTP ${response.code}")
            }
            val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start)
            val prefix = response.peekBody(PEEK_BYTES).string()
            if (isBadBody(prefix)) {
                throw IllegalStateException("疑似维护页或验证页")
            }
            ProbeResult(candidate.writeValue, elapsedMs)
        }
    }
}
