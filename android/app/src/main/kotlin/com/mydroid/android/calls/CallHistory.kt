package com.mydroid.android.calls

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.os.Bundle
import android.provider.CallLog
import android.net.Uri
import android.telecom.TelecomManager
import com.mydroid.android.Perms
import com.mydroid.android.contacts.ContactLookup
import com.mydroid.protocol.CallItem
import com.mydroid.protocol.CallWire

/** PROTOCOL.md 7.8: the call log, and placing a call. Worker thread only. Never logs numbers or names. */
class CallHistory(private val ctx: Context, private val contacts: ContactLookup) {
    fun canRead() = Perms.granted(ctx, Manifest.permission.READ_CALL_LOG)
    fun canDial() = Perms.granted(ctx, Manifest.permission.CALL_PHONE)

    fun list(limit: Int): List<CallItem> {
        val proj = arrayOf(CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.TYPE, CallLog.Calls.DATE, CallLog.Calls.DURATION)
        val out = ArrayList<CallItem>()
        val sort = "${CallLog.Calls.DATE} DESC"
        val c = try {
            ctx.contentResolver.query(CallLog.Calls.CONTENT_URI, proj, null, null, "$sort LIMIT $limit")
        } catch (e: IllegalArgumentException) {
            ctx.contentResolver.query(CallLog.Calls.CONTENT_URI, proj, null, null, sort)
        }
        c?.use {
            while (it.moveToNext() && out.size < limit) {
                val number = it.getString(0).orEmpty()
                val name = it.getString(1)?.takeIf { n -> n.isNotBlank() } ?: contacts.name(number) ?: contacts.pretty(number).ifBlank { "Unknown" }
                out += CallItem(number, name, CallWire.kindOf(it.getInt(2)), it.getLong(3), it.getLong(4))
            }
        }
        return out
    }

    /** Places the call through Telecom; the audio stays on the phone. Returns an error word, or null once it was handed over. */
    @SuppressLint("MissingPermission")
    fun dial(raw: String?): String? {
        val number = CallWire.dialable(raw) ?: return "number"
        if (!canDial()) return "permission"
        return try {
            val tm = ctx.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            tm.placeCall(Uri.fromParts("tel", number, null), Bundle())
            null
        } catch (e: SecurityException) {
            "permission"
        } catch (e: Exception) {
            "failed"
        }
    }
}
