package com.mydroid.android.remote

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import com.mydroid.protocol.LaserMapper
import com.mydroid.protocol.LaserThrottle
import com.mydroid.protocol.Message
import com.mydroid.protocol.RemoteWire

/** What the Remote screen needs from the app. [None] makes the screen renderable in tests and previews. */
interface RemoteApi {
    /** Fire and forget; input that can't be delivered is dropped on purpose (stale mouse moves help nobody). */
    fun send(m: Message)

    /** The Mac lacks Accessibility: ask it to show its prompt (`remote.ask`). */
    fun ask()

    /** While [handler] is set (Presenter mode on screen) the volume buttons call it: `true` for volume up. */
    fun volumeKeys(handler: ((up: Boolean) -> Unit)?)

    // PROTOCOL.md 16. Defaults do nothing, so previews and tests need no Mac.
    fun loadApps() {}
    fun launchApp(app: com.mydroid.protocol.MacApp) {}
    fun openFile(hit: com.mydroid.protocol.FsHit) {}
    fun startPresentation(hit: com.mydroid.protocol.FsHit, play: Boolean) {}
    fun watchPresent(on: Boolean) {}
    fun watchMedia(on: Boolean) {}
    fun mediaCommand(m: Message) {}
    /** Opens a link in the Mac's browser (a slides link, for instance). */
    fun openLink(url: String) {}
    /** Recent files (empty [query]) or a search of the Mac's shared folders. Blocks: call it off the main thread. Null when the Mac can't say. */
    fun findFiles(query: String): List<com.mydroid.protocol.FsHit>? = null

    /** Tests and previews only: pretend the laser sensor is (not) there. Null means ask the real sensor. */
    val laserPreview: Boolean? get() = null

    object None : RemoteApi {
        override fun send(m: Message) {}
        override fun ask() {}
        override fun volumeKeys(handler: ((up: Boolean) -> Unit)?) {}
    }
}

/** Where MainActivity looks when a volume key is pressed. Set only while Presenter mode is on screen. */
object VolumeKeys {
    @Volatile var handler: ((up: Boolean) -> Unit)? = null
}

/**
 * The game rotation vector sensor, delivered to the callback as a quaternion. It is registered only between [start] and
 * [stop], i.e. only while the laser button is held, so it costs nothing the rest of the time.
 */
class LaserSensor(context: Context) {
    private val sm = context.applicationContext.getSystemService(SensorManager::class.java)
    private val sensor: Sensor? = sm?.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
    private var listener: SensorEventListener? = null

    val available: Boolean get() = sensor != null

    fun start(onSample: (x: Double, y: Double, z: Double, w: Double, tMs: Long) -> Unit): Boolean {
        val s = sensor ?: return false
        stop()
        val l = object : SensorEventListener {
            override fun onSensorChanged(e: SensorEvent) {
                val v = e.values
                val x = v[0].toDouble(); val y = v[1].toDouble(); val z = v[2].toDouble()
                // `values[3]` is optional in the API; a unit quaternion gives it back.
                val w = if (v.size > 3) v[3].toDouble() else kotlin.math.sqrt((1 - x * x - y * y - z * z).coerceAtLeast(0.0))
                onSample(x, y, z, w, e.timestamp / 1_000_000L)
            }
            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }
        listener = l
        return sm?.registerListener(l, s, SensorManager.SENSOR_DELAY_GAME) == true
    }

    fun stop() {
        listener?.let { sm?.unregisterListener(it) }
        listener = null
    }
}

/**
 * Hold a button, point the phone: `in.laser` follows the phone's orientation, centred where it pointed when the button
 * went down. Press and release come from the UI thread, samples from the sensor (also the main thread).
 */
class LaserPointer(private val sensor: LaserSensor, private val send: (Message) -> Unit) {
    private val mapper = LaserMapper()
    private val throttle = LaserThrottle()
    private var on = false

    val available: Boolean get() = sensor.available

    fun press() {
        if (on || !sensor.available) return
        mapper.recenter(); throttle.reset()
        on = true
        send(RemoteWire.laser(true, 0.5, 0.5))
        val ok = sensor.start { x, y, z, w, t ->
            val p = mapper.update(x, y, z, w, t)
            if (on && throttle.allow(p.x, p.y, t)) send(RemoteWire.laser(true, p.x, p.y))
        }
        if (!ok) release()
    }

    fun release() {
        sensor.stop()
        if (!on) return
        on = false
        send(RemoteWire.laser(false))
    }
}
