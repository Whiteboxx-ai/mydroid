package com.mydroid.protocol

import kotlinx.serialization.json.*
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URLDecoder
import java.security.SecureRandom

data class HostPort(val host: String, val port: Int) {
    override fun toString(): String = if (host.contains(':')) "[$host]:$port" else "$host:$port"

    companion object {
        fun parse(s: String): HostPort? {
            val t = s.trim()
            if (t.isEmpty()) return null
            return try {
                if (t.startsWith("[")) {
                    val end = t.indexOf(']')
                    if (end < 0) return null
                    val port = t.substring(end + 1).removePrefix(":").toIntOrNull() ?: return null
                    HostPort(t.substring(1, end), port)
                } else {
                    val i = t.lastIndexOf(':')
                    if (i <= 0) return null
                    HostPort(t.substring(0, i), t.substring(i + 1).toInt())
                }
            } catch (e: NumberFormatException) {
                null
            }
        }
    }
}

/** Parsed contents of the QR: mydroid://pair?v=1&mac=..&n=..&s=..&a=.. */
class PairingUrl(val macId: String, val macName: String, val secret: ByteArray, val addresses: List<HostPort>) {
    companion object {
        /** Returns null for anything that is not a well-formed mydroid://pair URL. */
        fun parse(url: String): PairingUrl? {
            val u = url.trim()
            if (!u.startsWith("mydroid://pair", ignoreCase = true)) return null
            val q = u.substringAfter('?', "")
            if (q.isEmpty()) return null
            val params = HashMap<String, String>()
            for (kv in q.split('&')) {
                val i = kv.indexOf('=')
                if (i <= 0) continue
                params[kv.substring(0, i)] = kv.substring(i + 1)
            }
            if (params["v"] != "1") return null
            val mac = params["mac"]?.takeIf { it.isNotBlank() } ?: return null
            val name = params["n"]?.let { runCatching { URLDecoder.decode(it, "UTF-8") }.getOrDefault(it) } ?: "Mac"
            val s = params["s"] ?: return null
            val secret = runCatching { B64.decodeUrl(s) }.getOrNull() ?: return null
            if (secret.size != 32) return null
            val addrs = (params["a"] ?: "").split(',').mapNotNull {
                HostPort.parse(runCatching { URLDecoder.decode(it, "UTF-8") }.getOrDefault(it))
            }
            return PairingUrl(mac, name, secret, addrs)
        }
    }
}

/** What a phone needs to reconnect as an already-paired client. */
class Credentials(val phoneId: String, val macId: String, val ltk: ByteArray)

class DeviceIdentity(val name: String, val model: String, val androidSdk: Int)

/** An established, encrypted connection after the hello exchange. */
class SecureChannel(
    private val socket: Socket,
    private val input: InputStream,
    private val output: OutputStream,
    keys: SessionKeys,
    val macId: String,
    val remote: HostPort,
) : Closeable {
    private val sendCipher = FrameCipher(keys.c2s)
    private val recvCipher = FrameCipher(keys.s2c)
    private var sendCounter = 0L
    private var recvCounter = 0L
    val confirmCode: String = keys.confirmCode

    @Volatile
    var closed = false
        private set

    @Synchronized
    fun send(m: Message) {
        val body = sendCipher.seal(sendCounter, Codec.encode(m))
        try {
            Codec.writeFrame(output, body)
        } catch (e: IOException) {
            close()
            throw e
        }
        sendCounter++
    }

    /** Blocking. Throws on timeout (no frame within the socket read timeout), EOF or protocol error. */
    fun receive(): Message {
        val body = Codec.readFrame(input)
        val plain = recvCipher.open(recvCounter, body)
        recvCounter++
        return Codec.decode(plain)
    }

    override fun close() {
        closed = true
        try {
            socket.close()
        } catch (_: IOException) {
        }
    }
}

/** PROTOCOL.md §5.2. */
object Heartbeat {
    const val SCREEN_ON_MS = 25_000L
    const val SCREEN_OFF_MS = 90_000L
    const val IDLE_TIMEOUT_MS = 240_000
    fun intervalMs(screenOn: Boolean) = if (screenOn) SCREEN_ON_MS else SCREEN_OFF_MS
}

object Handshake {
    const val IDLE_TIMEOUT_MS = Heartbeat.IDLE_TIMEOUT_MS
    private val rng = SecureRandom()

    /**
     * Dial [target], do the plaintext hello exchange and derive session keys.
     * [expectedMac] is checked against the server's hello. Caller must then send `auth`.
     */
    fun connect(
        target: HostPort,
        phoneId: String,
        expectedMac: String,
        pairing: Boolean,
        ltk: ByteArray,
        connectTimeoutMs: Int = 4000,
        /** Platform hook to tune TCP keepalive intervals (the JVM can't); called right after connect. */
        tuneSocket: (Socket) -> Unit = {},
    ): SecureChannel {
        val socket = Socket()
        try {
            socket.tcpNoDelay = true
            socket.keepAlive = true
            socket.connect(InetSocketAddress(target.host, target.port), connectTimeoutMs)
            socket.soTimeout = connectTimeoutMs.coerceAtLeast(5000)
            val input = socket.getInputStream().buffered()
            val output = socket.getOutputStream().buffered()
            val nonceC = ByteArray(16).also { rng.nextBytes(it) }
            val hello = buildJsonObject {
                put("t", "hello"); put("v", 1); put("phone", phoneId); put("mac", expectedMac)
                put("nonce", B64.std(nonceC)); put("pairing", pairing)
            }
            Codec.writeFrame(output, hello.toString().toByteArray(Charsets.UTF_8))
            val reply = Codec.decode(
                // The server hello is a bare JSON frame (no header-length prefix), so parse it directly.
                wrapPlainJson(Codec.readFrame(input)),
            )
            if (reply.type != "hello" || reply.int("v") != 1) throw ProtocolException("bad server hello")
            val mac = reply.str("mac")
            if (mac != null && mac != expectedMac) throw ProtocolException("wrong Mac")
            val nonceS = B64.decodeStd(reply.str("nonce") ?: throw ProtocolException("hello without nonce"))
            val keys = Keys.session(ltk, nonceC, nonceS)
            socket.soTimeout = IDLE_TIMEOUT_MS
            runCatching { tuneSocket(socket) }
            return SecureChannel(socket, input, output, keys, mac ?: expectedMac, target)
        } catch (e: Exception) {
            try {
                socket.close()
            } catch (_: IOException) {
            }
            throw if (e is IOException) e else IOException(e.message, e)
        }
    }

    /** Re-wrap a bare JSON frame in the header-length format so Codec.decode can parse it. */
    private fun wrapPlainJson(json: ByteArray): ByteArray {
        val out = ByteArray(4 + json.size)
        out[0] = (json.size ushr 24).toByte(); out[1] = (json.size ushr 16).toByte()
        out[2] = (json.size ushr 8).toByte(); out[3] = json.size.toByte()
        System.arraycopy(json, 0, out, 4, json.size)
        return out
    }
}
