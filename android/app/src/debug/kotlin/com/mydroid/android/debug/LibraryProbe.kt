package com.mydroid.android.debug

import android.Manifest
import android.content.Context
import android.graphics.BitmapFactory
import android.util.Log
import com.mydroid.android.Perms
import com.mydroid.android.manager
import com.mydroid.android.data.Settings
import com.mydroid.android.net.RequestRouter
import com.mydroid.protocol.Codec
import com.mydroid.protocol.FrameBudget
import com.mydroid.protocol.Message
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put

private const val TAG = "MydroidDebug"

/**
 * Debug builds only (`am broadcast -n com.whiteboxxai.mydroid/com.mydroid.android.debug.DebugReceiver -a com.mydroid.android.debug.LIB_TEST`).
 * Runs the PROTOCOL.md 7.5 to 7.8 request handlers locally against the real provider data and logs ONLY counts, byte
 * sizes and timings. It never logs a name, number, message, date, id or any content, and never runs sms.send,
 * call.dial or photos.get.
 */
object LibraryProbe {
    private class Out { val msgs = ArrayList<Message>() }

    fun run(ctx: Context) {
        val out = Out()
        val settings = Settings(photos = true, calls = true, smsHistory = true)
        val router = RequestRouter(ctx, { settings }, { out.msgs += it; true }, { null }, Any(), ctx.manager().macFiles)
        fun perm(p: String) = Perms.granted(ctx, p)
        Log.i(TAG, "LIB perms readSms=${perm(Manifest.permission.READ_SMS)} sendSms=${perm(Manifest.permission.SEND_SMS)} contacts=${perm(Manifest.permission.READ_CONTACTS)} " +
            "callLog=${perm(Manifest.permission.READ_CALL_LOG)} callPhone=${perm(Manifest.permission.CALL_PHONE)} photos=${Perms.hasPhotoAccess(ctx)} fullPhotos=${Perms.hasFullPhotoAccess(ctx)}")

        fun step(label: String, req: Message): List<Message> {
            out.msgs.clear()
            val t0 = System.nanoTime()
            router.run(req, enforce = false)
            val ms = (System.nanoTime() - t0) / 1_000_000
            val bytes = out.msgs.sumOf { Codec.encode(it).size }
            Log.i(TAG, "LIB $label responses=${out.msgs.size} bytes=$bytes ms=$ms")
            return out.msgs.toList()
        }

        // ---- 7.5 SMS
        val threadsMsg = step("sms.threads.get limit=50", Message.of("sms.threads.get") { put("limit", 50) }).firstOrNull()
        if (threadsMsg?.type == "sms.error") Log.i(TAG, "LIB sms.threads error=${threadsMsg.str("error")}")
        val threads = (threadsMsg?.header?.get("threads") as? JsonArray)?.map { it.jsonObject } ?: emptyList()
        if (threadsMsg != null) {
            Log.i(TAG, "LIB sms.threads count=${threads.size} withAvatar=${threads.count { it["avatar"] != null }} avatarBytes=${threads.sumOf { (it["avatar"]?.jsonPrimitive?.content?.length ?: 0) }} " +
                "unreadThreads=${threads.count { it["unread"]!!.jsonPrimitive.int > 0 }} groups=${threads.count { (it["addresses"] as JsonArray).size > 1 }} fitsFrame=${FrameBudget.fits(threadsMsg)} " +
                "newestFirst=${threads.map { it["date"]!!.jsonPrimitive.long }.let { d -> d == d.sortedDescending() }}")
        }
        if (threads.isNotEmpty()) {
            // Contact matching and photos, as counts only (single-recipient threads; alphanumeric sender ids never match).
            val deep = ArrayList(threads)
            var before = threads.last()["date"]!!.jsonPrimitive.long
            repeat(2) {
                val pg = (step("sms.threads.get deep", Message.of("sms.threads.get") { put("limit", 50); put("before", before) }).firstOrNull()?.header?.get("threads") as? JsonArray)?.map { it.jsonObject } ?: emptyList()
                if (pg.isNotEmpty()) { deep += pg; before = pg.last()["date"]!!.jsonPrimitive.long }
            }
            Log.i(TAG, "LIB sms.threads deep total=${deep.size} withAvatarField=${deep.count { it["avatar"] != null }} groups=${deep.count { (it["addresses"] as JsonArray).size > 1 }}")
            val singles = deep.map { (it["addresses"] as JsonArray) }.filter { it.size == 1 }.map { it[0].jsonPrimitive.content }
            Log.i(TAG, "LIB contacts singleThreads=${singles.size} numeric=${singles.count { a -> a.none { it.isLetter() } }} " +
                "named=${singles.count { router.contacts.name(it) != null }} withPhoto=${singles.count { router.contacts.info(it, true).avatar != null }}")
            // A few threads at once: shapes of real SMS/MMS data (counts per kind only).
            var smsN = 0; var mmsN = 0; var outN = 0; var placeholders = 0; var textMms = 0; var biggest = 0; var bytesMax = 0
            val statuses = HashMap<String, Int>()
            for (t in deep) {
                val id = t["threadId"]!!.jsonPrimitive.long
                val r = step("sms.messages.get deep thread", Message.of("sms.messages.get") { put("threadId", id); put("limit", 50) }).firstOrNull() ?: continue
                val arr = (r.header["messages"] as? JsonArray)?.map { it.jsonObject } ?: continue
                biggest = maxOf(biggest, arr.size); bytesMax = maxOf(bytesMax, Codec.encode(r).size)
                for (m in arr) {
                    val mms = m["mms"]?.jsonPrimitive?.boolean == true
                    if (mms) { mmsN++; if (m["body"]!!.jsonPrimitive.content.let { it.startsWith("[") && it.endsWith("]") }) placeholders++ else textMms++ } else smsN++
                    if (m["out"]!!.jsonPrimitive.boolean) outN++
                    statuses.merge(m["status"]!!.jsonPrimitive.content, 1, Int::plus)
                }
            }
            val callNums = router.calls.list(100).map { it.number }.filter { it.isNotBlank() }.distinct()
            Log.i(TAG, "LIB contacts calls distinctNumbers=${callNums.size} named=${callNums.count { router.contacts.name(it) != null }} withPhoto=${callNums.count { router.contacts.info(it, true).avatar != null }}")
            Log.i(TAG, "LIB sms.messages allDeepThreads sms=$smsN mms=$mmsN(placeholder=$placeholders text=$textMms) out=$outN status=$statuses largestPage=$biggest largestFrame=$bytesMax")
            val lastDate = threads.last()["date"]!!.jsonPrimitive.long
            val page2 = step("sms.threads.get before=<oldest of page 1>", Message.of("sms.threads.get") { put("limit", 50); put("before", lastDate) }).firstOrNull()
            val t2 = (page2?.header?.get("threads") as? JsonArray)?.map { it.jsonObject } ?: emptyList()
            val ids1 = threads.map { it["threadId"]!!.jsonPrimitive.long }.toSet()
            Log.i(TAG, "LIB sms.threads page2 count=${t2.size} overlapWithPage1=${t2.count { it["threadId"]!!.jsonPrimitive.long in ids1 }}")

            val tid = threads.first()["threadId"]!!.jsonPrimitive.long
            val m1 = step("sms.messages.get newest thread limit=50", Message.of("sms.messages.get") { put("threadId", tid); put("limit", 50) }).firstOrNull()
            val ms = (m1?.header?.get("messages") as? JsonArray)?.map { it.jsonObject } ?: emptyList()
            val dates = ms.map { it["date"]!!.jsonPrimitive.long }
            Log.i(TAG, "LIB sms.messages count=${ms.size} mms=${ms.count { it["mms"]?.jsonPrimitive?.boolean == true }} out=${ms.count { it["out"]!!.jsonPrimitive.boolean }} " +
                "status=${ms.groupingBy { it["status"]!!.jsonPrimitive.content }.eachCount()} oldestFirst=${dates == dates.sorted()} " +
                "fitsFrame=${m1?.let { FrameBudget.fits(it) }} uniqueIds=${ms.map { it["id"]!!.jsonPrimitive.long }.toSet().size == ms.size}")
            if (ms.isNotEmpty()) {
                val oldest = dates.first()
                val p2 = step("sms.messages.get before=<oldest of page 1>", Message.of("sms.messages.get") { put("threadId", tid); put("limit", 50); put("before", oldest) }).firstOrNull()
                val ms2 = (p2?.header?.get("messages") as? JsonArray)?.map { it.jsonObject } ?: emptyList()
                val ids = ms.map { it["id"]!!.jsonPrimitive.long }.toSet()
                Log.i(TAG, "LIB sms.messages page2 count=${ms2.size} overlapWithPage1=${ms2.count { it["id"]!!.jsonPrimitive.long in ids }} allOlder=${ms2.all { it["date"]!!.jsonPrimitive.long < oldest }}")
            }
        }

        // ---- 7.7 photos
        var firstIds = emptyList<Long>()
        for (album in listOf("all", "camera", "screenshots")) {
            val p = step("photos.list album=$album limit=60", Message.of("photos.list") { put("limit", 60); put("album", album) }).firstOrNull()
            val items = (p?.header?.get("items") as? JsonArray)?.map { it.jsonObject } ?: emptyList()
            val taken = items.map { it["taken"]!!.jsonPrimitive.long }
            Log.i(TAG, "LIB photos.page album=$album items=${items.size} more=${p?.bool("more")} error=${p?.str("error")} newestFirst=${taken == taken.sortedDescending()} " +
                "albums=${items.groupingBy { it["album"]!!.jsonPrimitive.content }.eachCount()} zeroDims=${items.count { it["w"]!!.jsonPrimitive.int <= 0 }}")
            if (album == "all") {
                firstIds = items.map { it["id"]!!.jsonPrimitive.long }
                if (items.isNotEmpty()) {
                    val edge = taken.last()
                    val p2 = step("photos.list album=all before=<oldest of page 1>", Message.of("photos.list") { put("limit", 60); put("before", edge) }).firstOrNull()
                    val i2 = (p2?.header?.get("items") as? JsonArray)?.map { it.jsonObject } ?: emptyList()
                    val ids1 = firstIds.toSet()
                    Log.i(TAG, "LIB photos.page page2 items=${i2.size} more=${p2?.bool("more")} overlapWithPage1=${i2.count { it["id"]!!.jsonPrimitive.long in ids1 }} allOlder=${i2.all { it["taken"]!!.jsonPrimitive.long < edge }}")
                }
            }
        }
        if (firstIds.isNotEmpty()) {
            val ids = firstIds.take(3)
            val th = step("photos.thumbs.get ids=${ids.size}", Message.of("photos.thumbs.get") { put("ids", JsonArray(ids.map { kotlinx.serialization.json.JsonPrimitive(it) })) })
            for ((n, t) in th.withIndex()) {
                val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(t.payload, 0, t.payload.size, o)
                Log.i(TAG, "LIB photos.thumb #$n type=${t.type} jpegBytes=${t.payload.size} px=${o.outWidth}x${o.outHeight} mime=${o.outMimeType} ok=${t.bool("ok")}")
            }
            // Same ids again: served from the in-memory cache.
            step("photos.thumbs.get again (cached)", Message.of("photos.thumbs.get") { put("ids", JsonArray(ids.map { kotlinx.serialization.json.JsonPrimitive(it) })) })
        }

        // ---- 7.8 calls
        val c = step("calls.list limit=100", Message.of("calls.list") { put("limit", 100) }).firstOrNull()
        val items = (c?.header?.get("items") as? JsonArray)?.map { it.jsonObject } ?: emptyList()
        val dates = items.map { it["date"]!!.jsonPrimitive.long }
        Log.i(TAG, "LIB calls.page items=${items.size} error=${c?.str("error")} kinds=${items.groupingBy { it["kind"]!!.jsonPrimitive.content }.eachCount()} newestFirst=${dates == dates.sortedDescending()} " +
            "unnamed=${items.count { it["name"]!!.jsonPrimitive.content == it["number"]!!.jsonPrimitive.content || it["name"]!!.jsonPrimitive.content == "Unknown" }}")
        // ---- sms.changed: the observer registers, takes a baseline without announcing anything, and unregisters.
        val t0 = System.nanoTime()
        val snap = router.sms.repo.threadSnapshot()
        Log.i(TAG, "LIB threadSnapshot threads=${snap.size} ms=${(System.nanoTime() - t0) / 1_000_000}")
        out.msgs.clear()
        router.sms.setObserving(true)
        Thread.sleep(2_000)
        router.sms.setObserving(false)
        Log.i(TAG, "LIB observer register+baseline+unregister ok, sms.changed sent=${out.msgs.count { it.type == "sms.changed" }}")
        Log.i(TAG, "LIB done")
    }
}
