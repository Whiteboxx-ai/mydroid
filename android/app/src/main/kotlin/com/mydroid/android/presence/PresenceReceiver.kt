package com.mydroid.android.presence

import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.mydroid.android.manager

/** BLE scan results (the Mac's service UUID appeared or went away) and Bluetooth turning on. Metadata only in the log. */
class PresenceReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) {
        val m = c.manager()
        if (!m.store.isPaired) return
        when (i.action) {
            Presence.ACTION_SCAN -> {
                val err = i.getIntExtra(BluetoothLeScanner.EXTRA_ERROR_CODE, 0)
                if (err != 0) { Log.w("MydroidBle", "scan error=$err"); return }
                val type = i.getIntExtra(BluetoothLeScanner.EXTRA_CALLBACK_TYPE, 0)
                Log.i("MydroidBle", "scan callback type=$type")
                when (type) {
                    ScanSettings.CALLBACK_TYPE_MATCH_LOST -> m.onMacNearby(false)
                    else -> m.onMacNearby(true, viaAllMatches = type == ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
                }
            }
            BluetoothAdapter.ACTION_STATE_CHANGED -> {
                val st = i.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)
                if (st == BluetoothAdapter.STATE_ON) { Log.i("MydroidBle", "bluetooth on"); m.start(); m.refreshPresence(force = true) }
                else if (st == BluetoothAdapter.STATE_OFF) { Log.i("MydroidBle", "bluetooth off"); m.refreshPresence(force = false) }
            }
        }
    }
}
