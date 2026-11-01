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
                // 30s readTimeout 的真实代价：Cloudflare 类服务器响应后不发 TLS close_notify，
                // okhttp 关连接时 SSLSocket 在 deplete 里傻等「耗尽残余输入」，正好挂满
                // readTimeout——这就是每个首次请求白等 30s 的元凶（线程栈实锤）。降到 5s：
                // 正常响应的读间隔远小于 5s，而关连接挂起最多 5s。
                .readTimeout(5, TimeUnit.SECONDS)
                .callTimeout(2, TimeUnit.MINUTES)
                .cache(
                    Cache(
                        directory = Files.createTempDirectory("m_network_cache").toFile(),
                        maxSize = 64L * 1024 * 1024, // 64 MiB：5MiB 会让二次访问大量 miss，重新走真实网络并再次触发关连接挂起
                    ),
                )
        builder.build()
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
