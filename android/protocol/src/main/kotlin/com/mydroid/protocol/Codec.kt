package com.mydroid.protocol

import kotlinx.serialization.json.*
import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer

const val MAX_FRAME = 1 shl 20
const val CHUNK_SIZE = 256 * 1024

/** A decoded protocol message: JSON header (always has "t") plus optional binary payload. */
class Message(val header: JsonObject, val payload: ByteArray = EMPTY) {
    val type: String get() = header["t"]?.jsonPrimitive?.content ?: ""

    fun str(k: String): String? = (header[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
    fun long(k: String): Long? = (header[k] as? JsonPrimitive)?.longOrNull
    fun int(k: String): Int? = (header[k] as? JsonPrimitive)?.intOrNull
    fun bool(k: String): Boolean? = (header[k] as? JsonPrimitive)?.booleanOrNull
    fun arr(k: String): JsonArray? = header[k] as? JsonArray
    fun obj(k: String): JsonObject? = header[k] as? JsonObject

    override fun toString(): String = "Message($header, payload=${payload.size}B)"

    companion object {
        val EMPTY = ByteArray(0)

        fun of(type: String, payload: ByteArray = EMPTY, build: JsonObjectBuilder.() -> Unit = {}): Message =
            Message(buildJsonObject { put("t", type); build() }, payload)
    }
}

object Codec {
    /** Plaintext inside an encrypted frame: u32 H || header JSON || payload. */
    fun encode(m: Message): ByteArray {
        val h = m.header.toString().toByteArray(Charsets.UTF_8)
        val buf = ByteBuffer.allocate(4 + h.size + m.payload.size)
        buf.putInt(h.size).put(h).put(m.payload)
        return buf.array()
    }

    fun decode(plain: ByteArray): Message {
        if (plain.size < 4) throw ProtocolException("message too short")
        val h = ByteBuffer.wrap(plain).int
        if (h < 0 || h > plain.size - 4) throw ProtocolException("bad header length")
        val header = try {
            Json.parseToJsonElement(String(plain, 4, h, Charsets.UTF_8)) as? JsonObject
        } catch (e: Exception) {
            null
        } ?: throw ProtocolException("bad header json")
        if (header["t"] !is JsonPrimitive) throw ProtocolException("header has no type")
        return Message(header, plain.copyOfRange(4 + h, plain.size))
    }

    fun readFrame(input: InputStream): ByteArray {
        val d = DataInputStream(input)
        val len = try {
            d.readInt()
        } catch (e: EOFException) {
            throw EOFException("connection closed")
        }
        if (len < 0 || len > MAX_FRAME) throw ProtocolException("frame too large: $len")
        val b = ByteArray(len)
        d.readFully(b)
        return b
    }

    fun writeFrame(out: OutputStream, body: ByteArray) {
        if (body.size > MAX_FRAME) throw ProtocolException("frame too large: ${body.size}")
        val buf = ByteBuffer.allocate(4 + body.size)
        buf.putInt(body.size).put(body)
        out.write(buf.array())
        out.flush()
    }
}
