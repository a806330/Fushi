/*
 * 把 SSLSocket.close() 的「耗尽残余输入」等待压到 250ms。
 *
 * 背景（线程栈实锤，2026-11-01）：Cloudflare 类服务器响应完不发 TLS close_notify，
 * okhttp 关闭连接时 SSLSocketImpl.duplexCloseOutput → bruteForceCloseInput →
 * deplete 会在 socket read 上挂满当前 SO_TIMEOUT（此前 readTimeout=30s，即每个
 * 缓存未命中的请求白等 30s）。
 *
 * 做法：包装 socket，在 close() 前把 SO_TIMEOUT 临时压到 250ms。close 完成后不
 * 恢复——被关闭的连接即将废弃；若 okhttp 把连接归还池复用，它会在复用前重设
 * readTimeout。close 耗时超过 1s 时打点，便于确认 250ms 上限稳定生效。
 */
package eu.kanade.tachiyomi.network

import java.net.InetAddress
import java.net.Socket
import javax.net.ssl.HandshakeCompletedListener
import javax.net.ssl.SSLParameters
import javax.net.ssl.SSLSession
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

class FastCloseSSLSocketFactory(
    private val delegate: SSLSocketFactory,
) : SSLSocketFactory() {

    private fun wrap(socket: Socket): Socket {
        val ssl = socket as? SSLSocket ?: return socket
        return FastCloseSSLSocket.create(ssl)
    }

    override fun getDefaultCipherSuites(): Array<String> = delegate.defaultCipherSuites

    override fun getSupportedCipherSuites(): Array<String> = delegate.supportedCipherSuites

    override fun createSocket(
        socket: Socket?,
        host: String?,
        port: Int,
        autoClose: Boolean,
    ): Socket = wrap(delegate.createSocket(socket, host, port, autoClose))

    override fun createSocket(host: String?, port: Int): Socket =
        wrap(delegate.createSocket(host, port))

    override fun createSocket(
        host: String?,
        port: Int,
        localHost: InetAddress?,
        localPort: Int,
    ): Socket = wrap(delegate.createSocket(host, port, localHost, localPort))

    override fun createSocket(host: InetAddress?, port: Int): Socket =
        wrap(delegate.createSocket(host, port))

    override fun createSocket(
        address: InetAddress?,
        port: Int,
        localAddress: InetAddress?,
        localPort: Int,
    ): Socket = wrap(delegate.createSocket(address, port, localAddress, localPort))
}

class FastCloseSSLSocket private constructor(
    private val delegate: SSLSocket,
) : SSLSocket() {

    override fun close() {
        val start = System.currentTimeMillis()
        try {
            delegate.soTimeout = CLOSE_DRAIN_TIMEOUT_MS
        } catch (_: Exception) {
            // socket 已关/异常状态：直接尝试关闭。
        }
        try {
            delegate.close()
        } catch (_: Exception) {
            // 与 okhttp closeQuietly 同语义：关闭失败静默。
        }
        val elapsed = System.currentTimeMillis() - start
        if (elapsed > 1000) {
            System.err.println(
                "[Fushi][sidecar-net] slow SSLSocket close ms=$elapsed " +
                    "remote=${delegate.inetAddress?.hostAddress}:${delegate.port}",
            )
        }
    }

    override fun startHandshake() = delegate.startHandshake()

    override fun getInputStream() = delegate.getInputStream()

    override fun getOutputStream() = delegate.getOutputStream()

    override fun getSupportedCipherSuites(): Array<String> = delegate.supportedCipherSuites

    override fun getEnabledCipherSuites(): Array<String> = delegate.enabledCipherSuites

    override fun setEnabledCipherSuites(suites: Array<out String>?) {
        delegate.enabledCipherSuites = suites
    }

    override fun getSupportedProtocols(): Array<String> = delegate.supportedProtocols

    override fun getEnabledProtocols(): Array<String> = delegate.enabledProtocols

    override fun setEnabledProtocols(protocols: Array<out String>?) {
        delegate.enabledProtocols = protocols
    }

    override fun getSession(): SSLSession = delegate.session

    override fun getHandshakeSession(): SSLSession = delegate.handshakeSession

    override fun addHandshakeCompletedListener(listener: HandshakeCompletedListener?) {
        delegate.addHandshakeCompletedListener(listener)
    }

    override fun removeHandshakeCompletedListener(listener: HandshakeCompletedListener?) {
        delegate.removeHandshakeCompletedListener(listener)
    }

    override fun setUseClientMode(mode: Boolean) {
        delegate.useClientMode = mode
    }

    override fun getUseClientMode(): Boolean = delegate.useClientMode

    override fun setNeedClientAuth(need: Boolean) {
        delegate.needClientAuth = need
    }

    override fun getNeedClientAuth(): Boolean = delegate.needClientAuth

    override fun setWantClientAuth(want: Boolean) {
        delegate.wantClientAuth = want
    }

    override fun getWantClientAuth(): Boolean = delegate.wantClientAuth

    override fun setEnableSessionCreation(enable: Boolean) {
        delegate.enableSessionCreation = enable
    }

    override fun getEnableSessionCreation(): Boolean = delegate.enableSessionCreation

    override fun getSSLParameters(): SSLParameters = delegate.sslParameters

    override fun setSSLParameters(params: SSLParameters?) {
        delegate.sslParameters = params
    }

    override fun getApplicationProtocol(): String = delegate.applicationProtocol

    override fun getHandshakeApplicationProtocol(): String = delegate.handshakeApplicationProtocol

    override fun getInetAddress(): InetAddress? = delegate.inetAddress

    override fun getLocalAddress(): InetAddress = delegate.localAddress

    override fun getPort(): Int = delegate.port

    override fun getLocalPort(): Int = delegate.localPort

    override fun getRemoteSocketAddress(): java.net.SocketAddress? = delegate.remoteSocketAddress

    override fun getLocalSocketAddress(): java.net.SocketAddress? = delegate.localSocketAddress

    override fun isBound(): Boolean = delegate.isBound

    override fun isConnected(): Boolean = delegate.isConnected

    override fun isClosed(): Boolean = delegate.isClosed

    override fun setSoTimeout(timeout: Int) {
        delegate.soTimeout = timeout
    }

    override fun getSoTimeout(): Int = delegate.soTimeout

    override fun setSoLinger(on: Boolean, linger: Int) {
        delegate.setSoLinger(on, linger)
    }

    override fun getSoLinger(): Int = delegate.soLinger

    override fun setTcpNoDelay(on: Boolean) {
        delegate.tcpNoDelay = on
    }

    override fun getTcpNoDelay(): Boolean = delegate.tcpNoDelay

    override fun setKeepAlive(on: Boolean) {
        delegate.keepAlive = on
    }

    override fun getKeepAlive(): Boolean = delegate.keepAlive

    override fun setOOBInline(on: Boolean) {
        delegate.oobInline = on
    }

    override fun getOOBInline(): Boolean = delegate.oobInline

    override fun setReuseAddress(on: Boolean) {
        delegate.reuseAddress = on
    }

    override fun getReuseAddress(): Boolean = delegate.reuseAddress

    override fun setTrafficClass(tc: Int) {
        delegate.trafficClass = tc
    }

    override fun getTrafficClass(): Int = delegate.trafficClass

    override fun shutdownInput() = delegate.shutdownInput()

    override fun shutdownOutput() = delegate.shutdownOutput()

    override fun sendUrgentData(data: Int) = delegate.sendUrgentData(data)

    override fun getChannel(): java.nio.channels.SocketChannel? = delegate.channel

    override fun toString(): String = delegate.toString()

    companion object {
        const val CLOSE_DRAIN_TIMEOUT_MS = 250

        fun create(ssl: SSLSocket): SSLSocket = FastCloseSSLSocket(ssl)
    }
}
