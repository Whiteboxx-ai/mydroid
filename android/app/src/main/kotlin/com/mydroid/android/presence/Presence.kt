package com.mydroid.android.presence

import android.Manifest
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanSettings
import android.companion.AssociationRequest
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.annotation.RequiresApi
import com.mydroid.android.Perms
import com.mydroid.android.data.Store
import com.mydroid.protocol.Ble
import java.util.UUID

enum class PresenceStatus { Unsupported, NeedsPermission, NeedsAssociation, Ready }

/**
 * Bluetooth LE presence (PROTOCOL.md 7.1): a CompanionDeviceManager association on the Mac's per-pairing
 * service UUID (for background privileges) plus a hardware-filtered, low-power, PendingIntent scan on the same UUID.
 * BLE carries no data. Without permission or association everything here is inert and the app keeps its old behaviour.
 */
object Presence {
    private const val TAG = "MydroidBle"
    const val ACTION_SCAN = "com.mydroid.android.BLE_PRESENCE"
    private const val REQ_SCAN = 7101

    val permissions: Array<String> get() = if (Build.VERSION.SDK_INT >= 31)
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT) else emptyArray()

    fun supported(c: Context) =
        Build.VERSION.SDK_INT >= 31 && c.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) &&
            c.packageManager.hasSystemFeature(PackageManager.FEATURE_COMPANION_DEVICE_SETUP)

    fun hasPermissions(c: Context) = permissions.all { Perms.granted(c, it) }

    fun offerWatchProfile(notifications: Boolean) = notifications && Build.VERSION.SDK_INT >= 35

    private fun cdm(c: Context): CompanionDeviceManager? = c.getSystemService(CompanionDeviceManager::class.java)
    private fun adapter(c: Context): BluetoothAdapter? = c.getSystemService(BluetoothManager::class.java)?.adapter

    fun bluetoothOn(c: Context) = adapter(c)?.isEnabled == true

    /** Ids of our CDM associations (the system is the source of truth; adb-created ones count too). */
    fun associationIds(c: Context): List<Int> = try {
        if (Build.VERSION.SDK_INT >= 33) cdm(c)?.myAssociations?.map { it.id } ?: emptyList()
        else @Suppress("DEPRECATION") (cdm(c)?.associations?.map { 0 } ?: emptyList())
    } catch (e: Exception) {
        emptyList()
    }

    fun hasAssociation(c: Context) = associationIds(c).isNotEmpty()

    fun status(c: Context): PresenceStatus = when {
        !supported(c) -> PresenceStatus.Unsupported
        !hasPermissions(c) -> PresenceStatus.NeedsPermission
        !hasAssociation(c) -> PresenceStatus.NeedsAssociation
        else -> PresenceStatus.Ready
    }

    /** Presence drives the service lifecycle only when the phone can actually see the Mac's advertisement. */
    fun ready(c: Context) = status(c) == PresenceStatus.Ready && Store(c).isPaired && bluetoothOn(c)

    fun uuid(c: Context): UUID? {
        val ltk = Store(c).credentials()?.ltk ?: return null
        return UUID.fromString(Ble.serviceUuid(ltk))
    }

    // ------------------------------------------------------------------ association

    /** Shows the system picker. [launch] gets the dialog to start (needs one tap from the user). */
    @RequiresApi(31)
    fun associate(c: Context, launch: (IntentSender) -> Unit, failed: (String) -> Unit, watch: Boolean, created: () -> Unit) {
        val m = cdm(c) ?: return failed("This phone can't pair nearby")
        val u = uuid(c) ?: return failed("Pair with your Mac first")
        val filter = BluetoothLeDeviceFilter.Builder()
            .setScanFilter(ScanFilter.Builder().setServiceUuid(ParcelUuid(u)).build()).build()
        val rb = AssociationRequest.Builder().addDeviceFilter(filter).setSingleDevice(false)
        // Watch profile: Android grants the companion-watch role, which includes seeing OTPs that
        // Android 16 otherwise redacts from notification listeners. Opt-in only.
        if (watch) rb.setDeviceProfile(AssociationRequest.DEVICE_PROFILE_WATCH)
        val req = rb.build()
        val cb = object : CompanionDeviceManager.Callback() {
            @Deprecated("Deprecated in Java")
            override fun onDeviceFound(chooserLauncher: IntentSender) { launch(chooserLauncher) }
            override fun onAssociationPending(intentSender: IntentSender) { launch(intentSender) }
            override fun onAssociationCreated(associationInfo: android.companion.AssociationInfo) {
                Store(c).assocId = associationInfo.id
                Log.i(TAG, "association created id=${associationInfo.id} watch=${associationInfo.deviceProfile == AssociationRequest.DEVICE_PROFILE_WATCH}")
                // The system has just committed it, so this is the moment a plain one can be dropped for sure.
                if (watch) dropPlainSoon(c)
                created()
            }
            override fun onFailure(error: CharSequence?) { failed("Mac not found. Wake it and try again") }
        }
        try {
            if (Build.VERSION.SDK_INT >= 33) m.associate(req, { r -> Handler(Looper.getMainLooper()).post(r) }, cb)
            else @Suppress("DEPRECATION") m.associate(req, cb, Handler(Looper.getMainLooper()))
        } catch (e: Exception) {
            Log.w(TAG, "associate failed: ${e.javaClass.simpleName}")
            failed("Couldn't start pairing. Try again")
        }
    }

    /**
     * Once a watch association exists it covers presence too; drop older plain ones so there's just one, and point
     * `assocId` at the watch one.
     *
     * Why a plain one used to survive: the association dialog reports "done" to the activity a moment before Android has
     * committed the new association, so `isWatch()` was still false when this ran from the result callback and from
     * `onResume`, and nothing ran again until the user next left and came back to the app. It is now also called from
     * `onAssociationCreated`, retried shortly after the dialog closes ([dropPlainSoon]), and on every presence refresh.
     * `assocId` also used to be taken from the first entry of a list read straight after the removal, which could still be the plain one.
     */
    fun dropPlainIfWatch(c: Context): Boolean {
        if (Build.VERSION.SDK_INT < 33) return true
        try {
            val m = cdm(c) ?: return true
            val all = m.myAssociations
            val watch = all.filter { it.deviceProfile == AssociationRequest.DEVICE_PROFILE_WATCH }
            if (watch.isEmpty()) return false
            val plain = all.filter { it.deviceProfile != AssociationRequest.DEVICE_PROFILE_WATCH }
            var failed = 0
            plain.forEach { a ->
                try { m.disassociate(a.id) } catch (e: Exception) { failed++; Log.w(TAG, "dropPlainIfWatch: disassociate failed: ${e.javaClass.simpleName}") }
            }
            if (plain.isNotEmpty()) Log.i(TAG, "dropPlainIfWatch: removed=${plain.size - failed} failed=$failed kept=${watch.size}")
            // Never trust a list read straight after removal: the watch one is the answer by construction.
            Store(c).assocId = watch.maxOf { it.id }
            return failed == 0
        } catch (e: Exception) {
            Log.w(TAG, "dropPlainIfWatch failed: ${e.javaClass.simpleName}")
            return true
        }
    }

    /** The system commits a new association a beat after its dialog closes. Try again a few times, then give up quietly. */
    fun dropPlainSoon(c: Context) {
        val app = c.applicationContext
        val h = Handler(Looper.getMainLooper())
        var tries = 0
        lateinit var step: Runnable
        step = Runnable {
            // Done once a watch association exists and no plain one is left; otherwise wait and look again (up to ~10 s).
            val settled = dropPlainIfWatch(app) && (!isWatch(app) || plainCount(app) == 0)
            if (!settled && ++tries < 8) h.postDelayed(step, 1_250)
        }
        h.post(step)
    }

    private fun plainCount(c: Context): Int = try {
        if (Build.VERSION.SDK_INT >= 33) cdm(c)?.myAssociations?.count { it.deviceProfile != AssociationRequest.DEVICE_PROFILE_WATCH } ?: 0 else 0
    } catch (e: Exception) { 0 }

    /** True when an association uses the watch profile (see [associate]). */
    fun watchAssociationId(c: Context): Int? = try {
        if (Build.VERSION.SDK_INT < 33) null else cdm(c)?.myAssociations
            ?.filter { it.deviceProfile == AssociationRequest.DEVICE_PROFILE_WATCH }?.maxOfOrNull { it.id }
    } catch (e: Exception) { null }

    fun isWatch(c: Context): Boolean = watchAssociationId(c) != null

    fun disassociateAll(c: Context) {
        try {
            if (Build.VERSION.SDK_INT >= 33) cdm(c)?.myAssociations?.forEach { cdm(c)?.disassociate(it.id) }
        } catch (e: Exception) {
            Log.w(TAG, "disassociate failed: ${e.javaClass.simpleName}")
        }
    }

    // ------------------------------------------------------------------ scan

    private fun pending(c: Context): PendingIntent =
        PendingIntent.getBroadcast(
            c, REQ_SCAN, Intent(ACTION_SCAN).setClass(c, PresenceReceiver::class.java),
            // Mutable: the Bluetooth stack adds the scan results to the intent.
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )

    /** True if the scan is registered with FIRST_MATCH|MATCH_LOST; [Registration.allMatches] says we fell back. */
    class Registration(val ok: Boolean, val allMatches: Boolean)

    @Volatile var allMatchesFallback = false
        private set

    @android.annotation.SuppressLint("MissingPermission")
    fun register(c: Context): Registration {
        if (!ready(c)) return Registration(false, false)
        val u = uuid(c) ?: return Registration(false, false)
        val scanner: BluetoothLeScanner = adapter(c)?.bluetoothLeScanner ?: return Registration(false, false)
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(u)).build())
        val pi = pending(c)
        return try {
            runCatching { scanner.stopScan(pi) }
            val first = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
                .setCallbackType(ScanSettings.CALLBACK_TYPE_FIRST_MATCH or ScanSettings.CALLBACK_TYPE_MATCH_LOST)
                .setMatchMode(ScanSettings.MATCH_MODE_STICKY).build()
            var err = try { scanner.startScan(filters, first, pi) } catch (e: IllegalArgumentException) { -1 }
            var all = false
            if (err != 0) {
                Log.w(TAG, "FIRST_MATCH|MATCH_LOST refused (err=$err); falling back to ALL_MATCHES")
                val fb = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
                    .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES).build()
                err = scanner.startScan(filters, fb, pi)
                all = true
            }
            allMatchesFallback = all
            Log.i(TAG, "scan registered ok=${err == 0} allMatches=$all err=$err")
            Registration(err == 0, all)
        } catch (e: SecurityException) {
            Log.w(TAG, "scan not allowed: ${e.javaClass.simpleName}")
            Registration(false, false)
        }
    }

    @android.annotation.SuppressLint("MissingPermission")
    fun unregister(c: Context) {
        try {
            if (hasPermissions(c)) adapter(c)?.bluetoothLeScanner?.stopScan(pending(c))
            Log.i(TAG, "scan unregistered")
        } catch (e: Exception) {
            // Bluetooth off or no permission: nothing registered anyway
        }
    }
}
