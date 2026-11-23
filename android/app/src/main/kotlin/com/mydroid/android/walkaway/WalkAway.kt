package com.mydroid.android.walkaway

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import android.util.Log
import com.mydroid.android.Perms
import com.mydroid.android.data.Settings
import com.mydroid.android.data.Store
import com.mydroid.protocol.Ble
import java.util.UUID

enum class WalkAwayStatus { Off, Unsupported, NeedsPermission, BluetoothOff, On }

/** What Android allows for the walk-away beacon (PROTOCOL.md 12). Pure reads, cheap to call. */
object WalkAway {
    val permissions: Array<String> get() = if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_ADVERTISE) else emptyArray()

    fun hasPermission(c: Context) = permissions.all { Perms.granted(c, it) }

    private fun adapter(c: Context): BluetoothAdapter? = c.getSystemService(BluetoothManager::class.java)?.adapter

    fun supported(c: Context) = c.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) && adapter(c) != null

    fun status(c: Context, s: Settings): WalkAwayStatus = when {
        !s.walkAway -> WalkAwayStatus.Off
        !supported(c) -> WalkAwayStatus.Unsupported
        !hasPermission(c) -> WalkAwayStatus.NeedsPermission
        adapter(c)?.isEnabled != true -> WalkAwayStatus.BluetoothOff
        else -> WalkAwayStatus.On
    }
}

/**
 * Advertises the phone's per-pairing UUID (PROTOCOL.md 12) so the Mac can tell when this phone walks away.
 * Low power, medium TX, non-connectable, the service UUID only and no timeout: no GATT server, no wakelock, nothing held
 * open. The advertisement is a system-level object, so [setActive]`(false)` is what ends it: callers must drive it from the
 * connection and the foreground service, never leave it running on its own.
 */
class WalkAwayAdvertiser(private val app: Context) {
    private val lock = Any()
    private var callback: AdvertiseCallback? = null

    val advertising: Boolean get() = synchronized(lock) { callback != null }

    @SuppressLint("MissingPermission")
    fun setActive(want: Boolean) {
        synchronized(lock) {
            if (want == (callback != null)) return
            if (want) start() else stop()
        }
    }

    @SuppressLint("MissingPermission")
    private fun start() {
        val ltk = Store(app).credentials()?.ltk ?: return
        val advertiser = try {
            app.getSystemService(BluetoothManager::class.java)?.adapter?.takeIf { it.isEnabled }?.bluetoothLeAdvertiser
        } catch (e: SecurityException) { null } ?: return
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(false)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(UUID.fromString(Ble.phoneServiceUuid(ltk))))
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .build()
        val cb = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) { Log.i(TAG, "walk-away beacon on") }
            override fun onStartFailure(errorCode: Int) {
                Log.w(TAG, "walk-away beacon failed code=$errorCode")
                synchronized(lock) { if (callback === this) callback = null }
            }
        }
        callback = cb
        try {
            advertiser.startAdvertising(settings, data, cb)
        } catch (e: Exception) {
            Log.w(TAG, "walk-away beacon not started: ${e.javaClass.simpleName}")
            callback = null
        }
    }

    @SuppressLint("MissingPermission")
    private fun stop() {
        val cb = callback ?: return
        callback = null
        try {
            app.getSystemService(BluetoothManager::class.java)?.adapter?.bluetoothLeAdvertiser?.stopAdvertising(cb)
            Log.i(TAG, "walk-away beacon off")
        } catch (e: Exception) {
            // Bluetooth already off or permission revoked: the system has dropped the advertisement itself
        }
    }

    private companion object { const val TAG = "MydroidWalkAway" }
}
