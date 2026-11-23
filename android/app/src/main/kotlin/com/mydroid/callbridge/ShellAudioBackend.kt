package com.mydroid.callbridge

import android.annotation.SuppressLint
import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Build
import android.os.Looper
import com.mydroid.protocol.AudioFmt
import com.mydroid.protocol.CallAudioBackend
import com.mydroid.protocol.CallTier
import com.mydroid.protocol.PcmSink
import com.mydroid.protocol.PcmSource
import java.lang.reflect.InvocationTargetException

/**
 * The Android half of the helper. Runs in a bare `app_process` as the shell user (uid 2000), so there is no Application and
 * no real Context: this builds one over ActivityThread's system context with shell's package and attribution, which is what
 * the platform checks for the call-audio APIs. Proven on the OnePlus (Android 16) by a spike; the reflective calls are hidden API.
 * Audio only ever flows through the PcmSource/PcmSink it returns; nothing here records to storage.
 */
@SuppressLint("NewApi", "PrivateApi", "DiscouragedPrivateApi", "SoonBlockedPrivateApi")
class ShellAudioBackend(private val log: (String) -> Unit) : CallAudioBackend {
    private val ctx: Context?
    private val am: AudioManager?

    init {
        var c: Context? = null
        var m: AudioManager? = null
        try {
            if (Looper.myLooper() == null) Looper.prepareMainLooper()
            c = ShellContext(systemContext())
            val ctor = AudioManager::class.java.getDeclaredConstructor(Context::class.java)
            ctor.isAccessible = true
            m = ctor.newInstance(c)
        } catch (t: Throwable) {
            log("audio setup failed: ${t.javaClass.simpleName} ${t.message}")
        }
        ctx = c; am = m
    }

    private class ShellContext(base: Context) : ContextWrapper(base) {
        override fun getPackageName() = SHELL
        override fun getOpPackageName() = SHELL
        override fun getAttributionSource(): AttributionSource =
            if (Build.VERSION.SDK_INT >= 31) AttributionSource.Builder(2000).setPackageName(SHELL).build() else super.getAttributionSource()
        override fun getApplicationContext(): Context = this
    }

    private fun systemContext(): Context {
        val at = Class.forName("android.app.ActivityThread")
        val ctor = at.getDeclaredConstructor().apply { isAccessible = true }
        val thread = ctor.newInstance()
        at.getDeclaredField("sCurrentActivityThread").apply { isAccessible = true }.set(null, thread)
        at.getDeclaredField("mSystemThread").apply { isAccessible = true }.setBoolean(thread, true)
        return at.getDeclaredMethod("getSystemContext").apply { isAccessible = true }.invoke(thread) as Context
    }

    private fun fmtIn() = AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(AudioFmt.RATE)
        .setChannelMask(AudioFormat.CHANNEL_IN_MONO).build()

    private fun fmtOut() = AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(AudioFmt.RATE)
        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build()

    /** Reflective AudioManager call. Failures come back as the real cause (IllegalStateException outside MODE_IN_CALL). */
    private fun invoke(name: String, vararg argTypes: Class<*>, args: Array<Any?> = emptyArray()): Any? {
        val m = am ?: throw IllegalStateException("no AudioManager")
        try {
            return AudioManager::class.java.getMethod(name, *argTypes).invoke(m, *args)
        } catch (e: InvocationTargetException) {
            throw e.cause ?: e
        }
    }

    override fun inCall(): Boolean = try { am?.mode == AudioManager.MODE_IN_CALL } catch (t: Throwable) { false }

    override fun probeTier(): CallTier {
        if (am == null) return CallTier.None
        val interceptable = try { invoke("isPstnCallAudioInterceptable") as? Boolean ?: false } catch (t: Throwable) { false }
        log("interceptable=$interceptable")
        if (interceptable && dryFull()) return CallTier.Full
        if (dryListen()) return CallTier.Listen
        return CallTier.None
    }

    /** True if the two factories exist and either work (we're in a call) or refuse only because we aren't in one. */
    private fun dryFull(): Boolean {
        return try {
            val rec = invoke("getCallDownlinkExtractionAudioRecord", AudioFormat::class.java, args = arrayOf(fmtIn())) as AudioRecord
            runCatching { rec.release() }
            val trk = invoke("getCallUplinkInjectionAudioTrack", AudioFormat::class.java, args = arrayOf(fmtOut())) as AudioTrack
            runCatching { trk.release() }
            true
        } catch (e: IllegalStateException) {
            true // "not in a call": the expected answer outside one. Confirmed (or downgraded) at the first route.
        } catch (e: NoSuchMethodException) {
            false
        } catch (t: Throwable) {
            log("full dry check: ${t.javaClass.simpleName}")
            false
        }
    }

    private fun dryListen(): Boolean {
        for (src in LISTEN_SOURCES) {
            try {
                val rec = captureRecord(src)
                val ok = rec.state == AudioRecord.STATE_INITIALIZED
                runCatching { rec.release() }
                if (ok) return true
            } catch (t: Throwable) {
                log("listen dry check source=$src: ${t.javaClass.simpleName}")
            }
        }
        return false
    }

    private fun captureRecord(source: Int): AudioRecord {
        val min = AudioRecord.getMinBufferSize(AudioFmt.RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        return AudioRecord.Builder().setContext(ctx!!).setAudioSource(source).setAudioFormat(fmtIn())
            .setBufferSizeInBytes(maxOf(min * 2, AudioFmt.RATE)).build()
    }

    override fun openDownlink(full: Boolean): PcmSource {
        var rec: AudioRecord? = null
        try {
            rec = if (full) {
                invoke("getCallDownlinkExtractionAudioRecord", AudioFormat::class.java, args = arrayOf(fmtIn())) as AudioRecord
            } else {
                var r: AudioRecord? = null
                var last: Throwable? = null
                for (src in LISTEN_SOURCES) {
                    try { r = captureRecord(src); if (r.state == AudioRecord.STATE_INITIALIZED) break; r.release(); r = null }
                    catch (t: Throwable) { last = t; r = null }
                }
                r ?: throw (last ?: IllegalStateException("capture not initialized"))
            }
            if (rec.state != AudioRecord.STATE_INITIALIZED) throw IllegalStateException("downlink record not initialized")
            rec.startRecording()
            if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) throw IllegalStateException("downlink record didn't start")
            val r = rec
            return object : PcmSource {
                override fun read(buf: ByteArray, off: Int, len: Int) = r.read(buf, off, len)
                override fun stop() { runCatching { r.stop() } }
                override fun release() { runCatching { r.release() } }
            }
        } catch (t: Throwable) {
            runCatching { rec?.stop() }; runCatching { rec?.release() }
            throw t
        }
    }

    override fun openUplink(): PcmSink {
        var trk: AudioTrack? = null
        try {
            trk = invoke("getCallUplinkInjectionAudioTrack", AudioFormat::class.java, args = arrayOf(fmtOut())) as AudioTrack
            if (trk.state != AudioTrack.STATE_INITIALIZED) throw IllegalStateException("uplink track not initialized")
            trk.play()
            val t = trk
            return object : PcmSink {
                override fun write(buf: ByteArray, off: Int, len: Int) = t.write(buf, off, len)
                override fun release() { runCatching { t.stop() }; runCatching { t.release() } }
            }
        } catch (t: Throwable) {
            runCatching { trk?.release() }
            throw t
        }
    }

    private companion object {
        const val SHELL = "com.android.shell"
        /** Caller only, then the whole call (which also carries the user's own voice; a fallback, not a first choice). */
        val LISTEN_SOURCES = intArrayOf(MediaRecorder.AudioSource.VOICE_DOWNLINK, MediaRecorder.AudioSource.VOICE_CALL)
    }
}
