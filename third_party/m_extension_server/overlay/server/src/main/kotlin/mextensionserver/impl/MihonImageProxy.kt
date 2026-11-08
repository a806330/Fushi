package mextensionserver.impl

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.online.HttpSource
import fi.iki.elonen.NanoHTTPD
import kotlinx.coroutines.runBlocking
import mextensionserver.controller.SourceCookieInjection
import java.util.UUID

/**
 * Keeps page requests inside the extension's OkHttp client.
 *
 * Some extensions use interceptors to turn a synthetic page URL into image
 * bytes. Returning that URL to the caller bypasses the interceptor, so page
 * entries are registered here and exposed through a loopback URL instead.
 */
internal object MihonImageProxy {
    private const val MAX_ENTRIES = 4096

    data class ImageData(
        val bytes: ByteArray,
        val contentType: String,
    )

    /**
     * Chapter image result plus the cookies the source jar held for its domain
     * after the fetch. The host re-owns the session (BUG-2425), so any cookie
     * the site rotated on this -- usually the most frequent -- path must ride
     * back to the host, exactly as [SourceImageHandler] already does for covers.
     */
    data class ImageResult(
        val data: ImageData,
        val jarCookies: String?,
    )

    private data class Entry(
        val key: String,
        val source: HttpSource,
        val page: Page,
    )

    private val lock = Any()
    private val entriesByToken = LinkedHashMap<String, Entry>(16, 0.75f, true)
    private val tokensByKey = mutableMapOf<String, String>()
    private val mapper = jacksonObjectMapper()

    @Volatile
    private var port: Int = 0

    fun configure(port: Int) {
        require(port > 0) { "Image proxy port must be positive" }
        this.port = port
    }

    fun register(
        source: HttpSource,
        page: Page,
    ): String? {
        val currentPort = port
        if (currentPort <= 0) return null

        val key =
            buildString {
                append(System.identityHashCode(source))
                append('\u0000')
                append(page.index)
                append('\u0000')
                append(page.url)
                append('\u0000')
                append(page.imageUrl.orEmpty())
            }
        val token =
            synchronized(lock) {
                tokensByKey[key]?.let { existingToken ->
                    entriesByToken[existingToken] = Entry(key, source, page)
                    return@synchronized existingToken
                }

                while (entriesByToken.size >= MAX_ENTRIES) {
                    val iterator = entriesByToken.entries.iterator()
                    val eldest = iterator.next()
                    iterator.remove()
                    tokensByKey.remove(eldest.value.key)
                }

                UUID.randomUUID().toString().also { newToken ->
                    entriesByToken[newToken] = Entry(key, source, page)
                    tokensByKey[key] = newToken
                }
            }

        return "http://127.0.0.1:$currentPort/image/$token"
    }

    /** Backwards-compatible entry point used when no host session is supplied. */
    fun fetch(token: String): ImageData? = fetch(token, null)?.data

    /**
     * Resolve and download one registered page.
     *
     * [session] is the inbound HTTP session carrying the host-owned login
     * session (BUG-2425). Chapter images are served through this proxy
     * (`/image/<token>`), reached by [ImageProxyHandler] WITHOUT the per-call
     * cookie header that the `/dalvik` and `/source-image` paths get. Those two
     * refill the sidecar jar on every browse; this one historically relied on
     * the jar still holding the session from a prior call. The moment the jar is
     * empty -- sidecar restart, source-data clear, or an image fetched before
     * any `/dalvik` refill -- a login-gated source silently loses its session
     * here and the chapter renders as "not signed in" even though the detail and
     * cover loaded fine. Injecting the host cookies before the fetch makes the
     * image path self-sufficient, mirroring [SourceCookieInjection] as used by
     * the cover/source-image path.
     */
    fun fetch(
        token: String,
        session: NanoHTTPD.IHTTPSession?,
    ): ImageResult? {
        val entry = synchronized(lock) { entriesByToken[token] } ?: return null
        val source = entry.source
        if (session != null) {
            SourceCookieInjection.injectRequestCookies(session, source)
            SourceCookieInjection.applyRequestUserAgent(session, source)
        }
        if (entry.page.imageUrl == null) {
            entry.page.imageUrl =
                runBlocking {
                    source.getImageUrl(entry.page)
                }
        }
        val data =
            source
                .fetchImage(entry.page)
                .map { response ->
                    // The Rx call adapter cancels its socket on unsubscription.
                    // Consume and close the body while onNext still owns the call;
                    // only detached image bytes may cross the blocking boundary.
                    response.use {
                        val body =
                            requireNotNull(it.body) {
                                "Extension returned an empty image response"
                            }
                        ImageData(
                            bytes = body.bytes(),
                            contentType =
                                body.contentType()?.toString()
                                    ?: "application/octet-stream",
                        )
                    }
                }.toBlocking()
                .single()
        // Report any session cookie the site rotated on this path back to the
        // host. Images are the most frequent calls, so they are typically what
        // first meets a session renewal.
        val jarCookies =
            if (session != null) {
                SourceCookieInjection.encodeJarCookies(
                    mapper,
                    source,
                    SourceCookieInjection.domainOf(source),
                )
            } else {
                null
            }
        return ImageResult(data = data, jarCookies = jarCookies)
    }

    fun clear() {
        synchronized(lock) {
            entriesByToken.clear()
            tokensByKey.clear()
        }
        port = 0
    }
}
