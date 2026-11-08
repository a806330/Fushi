package mextensionserver.controller

import fi.iki.elonen.NanoHTTPD
import io.github.oshai.kotlinlogging.KotlinLogging
import mextensionserver.impl.MihonImageProxy
import java.io.ByteArrayInputStream

/**
 * Chapter page images (`/image/<token>`).
 *
 * Overrides the upstream handler so the image path carries the host-owned login
 * session (BUG-2425) -- the upstream version predates that work and never
 * injected the host cookies, so a login-gated source could render its signed-in
 * detail and cover but fail every chapter image once the sidecar jar lost the
 * session (restart, source-data clear, or an image fetched before a `/dalvik`
 * refill). See [MihonImageProxy.fetch] for the full rationale.
 */
class ImageProxyHandler {
    private val logger = KotlinLogging.logger {}

    fun serve(session: NanoHTTPD.IHTTPSession): NanoHTTPD.Response {
        val token = session.uri.removePrefix(ROUTE_PREFIX)
        if (token.isEmpty() || token == session.uri) {
            return NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.NOT_FOUND,
                NanoHTTPD.MIME_PLAINTEXT,
                "Image not found",
            )
        }

        return try {
            val result =
                MihonImageProxy.fetch(token, session)
                    ?: return NanoHTTPD
                        .newFixedLengthResponse(
                            NanoHTTPD.Response.Status.NOT_FOUND,
                            NanoHTTPD.MIME_PLAINTEXT,
                            "Image not found",
                        ).withJarCookies(null)
            val image = result.data
            NanoHTTPD
                .newFixedLengthResponse(
                    NanoHTTPD.Response.Status.OK,
                    image.contentType,
                    ByteArrayInputStream(image.bytes),
                    image.bytes.size.toLong(),
                ).apply {
                    addHeader("Cache-Control", "private, max-age=86400")
                }.withJarCookies(result.jarCookies)
        } catch (error: Throwable) {
            logger.error(error) { "Error proxying extension image" }
            NanoHTTPD.newFixedLengthResponse(
                NanoHTTPD.Response.Status.INTERNAL_ERROR,
                NanoHTTPD.MIME_PLAINTEXT,
                error.message ?: error.javaClass.simpleName,
            )
        }
    }

    /** Attaches [SET_COOKIE_HEADER] when the call actually touched cookies. */
    private fun NanoHTTPD.Response.withJarCookies(payload: String?): NanoHTTPD.Response =
        apply { if (payload != null) addHeader(SET_COOKIE_HEADER, payload) }

    companion object {
        const val ROUTE_PREFIX = "/image/"
    }
}
