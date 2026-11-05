package eu.kanade.tachiyomi.network

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import android.content.Context
import eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor
import eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor
import eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor
import mextensionserver.impl.HostProxyPolicy
import okhttp3.Cache
import okhttp3.OkHttpClient
import okhttp3.brotli.BrotliInterceptor
import okhttp3.logging.HttpLoggingInterceptor
import java.nio.file.Files
import java.util.concurrent.TimeUnit

class NetworkHelper(
    val context: Context,
) {
    val cookieJar = MemoryCookieJar()

    val client by lazy {
        // A running HTTP/2 connection can accept new streams without consulting
        // ProxySelector. Keep calls independent so host policy changes apply to
        // the next request without interrupting existing image downloads.
        val builder =
            HostProxyPolicy
                .configureClient(OkHttpClient.Builder())
                .cookieJar(cookieJar)
                .addInterceptor { chain ->
                    val request = chain.request()
                    val netStart = System.currentTimeMillis()
                    try {
                        val response = chain.proceed(request)
                        System.err.println(
                            "[Fushi][sidecar-net] t=$netStart ${request.method} ${request.url} " +
                                "code=${response.code} ms=${System.currentTimeMillis() - netStart}",
                        )
                        response
                    } catch (error: Throwable) {
                        System.err.println(
                            "[Fushi][sidecar-net] t=$netStart ${request.method} ${request.url} " +
                                "err=${error.javaClass.simpleName} ms=${System.currentTimeMillis() - netStart}",
                        )
                        throw error
                    }
                }
                .addInterceptor(UncaughtExceptionInterceptor())
                .addInterceptor(UserAgentInterceptor(::defaultUserAgentProvider))
                .addInterceptor(CloudflareInterceptor())
                .addInterceptor(
                    HttpLoggingInterceptor().apply {
                        redactHeader("Authorization")
                        redactHeader("Proxy-Authorization")
                        level = HttpLoggingInterceptor.Level.BASIC
                    },
                ).addInterceptor(BrotliInterceptor)
                .connectTimeout(30, TimeUnit.SECONDS)
                // 关连接挂起已由 FastCloseSSLSocketFactory 独立压到 250ms（只影响 close，
                // 不碰正常读取），所以这里可以放宽读取容忍：5s 曾误杀 mycomic 偶发的
                // 慢响应（>5s 即 Read timed out → 重试耗尽 → 「加载失败」）。15s 兜住
                // 实测最慢 ~10s 的响应，同时仍能及时暴露真死链。
                .readTimeout(15, TimeUnit.SECONDS)
                .callTimeout(2, TimeUnit.MINUTES)
                .sslSocketFactory(
                    FastCloseSSLSocketFactory(javax.net.ssl.SSLContext.getDefault().socketFactory),
                    defaultTrustManager(),
                )
                .cache(
                    Cache(
                        directory = Files.createTempDirectory("m_network_cache").toFile(),
                        maxSize = 64L * 1024 * 1024, // 64 MiB：5MiB 会让二次访问大量 miss，重新走真实网络并再次触发关连接挂起
                    ),
                )
        builder.build()
    }

    /**
     * 系统 默认信任库 的 X509TrustManager，给 [FastCloseSSLSocketFactory] 配套。
     * 信任行为与 JVM 默认完全一致（包括运行期被宿主注入的自定义 CA——那些走的是
     * SSLContext.setDefault，getDefault() 会继承）。
     */
    private fun defaultTrustManager(): javax.net.ssl.X509TrustManager {
        val factory = javax.net.ssl.TrustManagerFactory.getInstance(
            javax.net.ssl.TrustManagerFactory.getDefaultAlgorithm(),
        )
        factory.init(null as java.security.KeyStore?)
        return factory.trustManagers.filterIsInstance<javax.net.ssl.X509TrustManager>().first()
    }

    val cloudflareClient by lazy {
        client
            .newBuilder()
            .addInterceptor(CloudflareInterceptor())
            .build()
    }

    private var defaultUserAgent: String = System.getProperty("http.agent").orEmpty()

    fun setUA(ua: String) {
        defaultUserAgent = ua
    }

    fun defaultUserAgentProvider() = defaultUserAgent
}
