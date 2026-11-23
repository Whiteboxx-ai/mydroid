package com.mydroid.android.sms

import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.provider.Telephony
import com.mydroid.android.contacts.ContactLookup
import com.mydroid.protocol.Page
import com.mydroid.protocol.Paging
import com.mydroid.protocol.SmsMsg
import com.mydroid.protocol.SmsThread
import com.mydroid.protocol.SmsWire
import com.mydroid.protocol.ThreadChangeTracker
import com.mydroid.protocol.ThreadNames
import java.util.concurrent.ConcurrentHashMap

/**
 * Read-only view of the telephony provider: conversations, messages and unread counts. Never writes; the system
 * (not this app) records messages we send. Must be called off the main thread. Never logs content.
 */
class SmsRepository(private val ctx: Context, private val contacts: ContactLookup) {
    private val cr = ctx.contentResolver
    private val canonical = ConcurrentHashMap<Long, String>()

    private val threadsUri: Uri = Telephony.Threads.CONTENT_URI.buildUpon().appendQueryParameter("simple", "true").build()

    /** Runs a provider query asking for `LIMIT n` in the sort order, retrying without it if the provider objects. */
    private fun query(uri: Uri, proj: Array<String>, sel: String?, args: Array<String>?, sort: String, limit: Int): Cursor? =
        try {
            cr.query(uri, proj, sel, args, "$sort LIMIT $limit")
        } catch (e: IllegalArgumentException) {
            cr.query(uri, proj, sel, args, sort)
        } catch (e: android.database.sqlite.SQLiteException) {
            cr.query(uri, proj, sel, args, sort)
        }

    // ------------------------------------------------------------------ threads

    private fun loadCanonical() {
        cr.query(Uri.parse("content://mms-sms/canonical-addresses"), arrayOf("_id", "address"), null, null, null)?.use { c ->
            while (c.moveToNext()) canonical[c.getLong(0)] = c.getString(1) ?: ""
        }
    }

    private fun addressesOf(recipientIds: String?): List<String> {
        val ids = recipientIds?.trim()?.split(' ', ',')?.mapNotNull { it.toLongOrNull() } ?: return emptyList()
        if (ids.any { !canonical.containsKey(it) }) loadCanonical()
        return ids.mapNotNull { canonical[it]?.takeIf { a -> a.isNotBlank() } }
    }

    private class ThreadRow(val id: Long, val date: Long, val recipients: String?, val snippet: String?, val hasAttachment: Boolean)

    fun threads(limit: Int, before: Long?): Page<SmsThread> {
        val cap = limit + Paging.TIE_EXTRA
        val rows = ArrayList<ThreadRow>()
        val proj = arrayOf("_id", "date", "message_count", "recipient_ids", "snippet", "has_attachment")
        query(threadsUri, proj, if (before != null) "date < ?" else null, if (before != null) arrayOf(before.toString()) else null, "date DESC", cap)?.use { c ->
            while (c.moveToNext()) {
                if (c.getInt(2) <= 0) continue // an empty thread (a draft, or one left behind by a deleted conversation)
                rows += ThreadRow(c.getLong(0), c.getLong(1), c.getString(3), c.getString(4), c.getInt(5) != 0)
            }
        }
        val page = Paging.page(rows, limit, { it.date }, moreBeyondInput = rows.size >= cap)
        val unread = unreadByThread()
        val out = page.items.map { r ->
            val addrs = addressesOf(r.recipients)
            val single = addrs.size == 1
            val info = if (single) contacts.info(addrs[0], withPhoto = true) else null
            val labels = addrs.map { contacts.label(it) }
            SmsThread(
                threadId = r.id, addresses = addrs,
                name = ThreadNames.title(labels).ifBlank { "Unknown" },
                snippet = SmsWire.snippet(r.snippet, r.hasAttachment), date = r.date,
                unread = unread[r.id] ?: 0, avatar = info?.avatar,
            )
        }
        return Page(out, page.more)
    }

    /** Unread received messages per thread (SMS and MMS). One narrow query each; unread rows are few. */
    private fun unreadByThread(): Map<Long, Int> {
        val m = HashMap<Long, Int>()
        fun count(uri: Uri, sel: String) {
            runCatching {
                cr.query(uri, arrayOf("thread_id"), sel, null, null)?.use { c -> while (c.moveToNext()) m.merge(c.getLong(0), 1, Int::plus) }
            }
        }
        count(Telephony.Sms.CONTENT_URI, "read = 0 AND type = 1")
        count(Telephony.Mms.CONTENT_URI, "read = 0 AND msg_box = 1")
        return m
    }

    /** id -> (date, message count, read) for every thread; cheap, used to find out which thread changed. */
    fun threadSnapshot(): Map<Long, ThreadChangeTracker.Sig> {
        val m = HashMap<Long, ThreadChangeTracker.Sig>()
        cr.query(threadsUri, arrayOf("_id", "date", "message_count", "read"), null, null, null)?.use { c ->
            while (c.moveToNext()) m[c.getLong(0)] = ThreadChangeTracker.Sig(c.getLong(1), c.getInt(2), c.getInt(3))
        }
        return m
    }

    /** The system's thread for this set of recipients (creating an empty one if there is none). Only used when sending. */
    fun threadIdFor(addresses: Collection<String>): Long = Telephony.Threads.getOrCreateThreadId(ctx, addresses.toSet())

    // ------------------------------------------------------------------ messages

    /** [threadId]'s newest [limit] messages older than [before], returned oldest first. */
    fun messages(threadId: Long, limit: Int, before: Long?): Page<SmsMsg> {
        val cap = limit + Paging.TIE_EXTRA
        val sms = ArrayList<SmsMsg>()
        val smsSel = "thread_id = ?" + if (before != null) " AND date < ?" else ""
        val smsArgs = if (before != null) arrayOf(threadId.toString(), before.toString()) else arrayOf(threadId.toString())
        query(Telephony.Sms.CONTENT_URI, arrayOf("_id", "address", "body", "date", "type"), smsSel, smsArgs, "date DESC", cap)?.use { c ->
            while (c.moveToNext()) {
                val type = c.getInt(4)
                sms += SmsMsg(
                    id = c.getLong(0), from = if (SmsWire.isOutSmsType(type)) "" else c.getString(1) ?: "",
                    body = c.getString(2) ?: "", date = c.getLong(3), out = SmsWire.isOutSmsType(type), status = SmsWire.statusOfSmsType(type),
                )
            }
        }
        // MMS dates are in seconds. `date < before` in ms means `sec < ceil(before / 1000)`.
        val mms = ArrayList<SmsMsg>()
        val mmsSel = "thread_id = ?" + if (before != null) " AND date < ?" else ""
        val mmsArgs = if (before != null) arrayOf(threadId.toString(), ((before + 999) / 1000).toString()) else arrayOf(threadId.toString())
        runCatching {
            query(Telephony.Mms.CONTENT_URI, arrayOf("_id", "date", "msg_box"), mmsSel, mmsArgs, "date DESC", cap)?.use { c ->
                while (c.moveToNext()) {
                    val box = c.getInt(2)
                    mms += SmsMsg(id = -c.getLong(0), from = "", body = "", date = c.getLong(1) * 1000, out = SmsWire.isOutMmsBox(box), status = SmsWire.statusOfMmsBox(box), mms = true)
                }
            }
        }
        val merged = Paging.merge(sms, mms) { it.date }
        val page = Paging.page(merged, limit, { it.date }, moreBeyondInput = sms.size >= cap || mms.size >= cap)
        val filled = page.items.map { m -> if (m.mms) fillMms(m) else m }
        return Page(filled.asReversed(), page.more)
    }

    /** Text part (or a placeholder) and, for received messages, the sender. Only done for MMS that made the page. */
    private fun fillMms(m: SmsMsg): SmsMsg {
        val mmsId = -m.id
        val texts = ArrayList<String>()
        val types = ArrayList<String>()
        runCatching {
            cr.query(Uri.parse("content://mms/$mmsId/part"), arrayOf("_id", "ct", "text"), null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val ct = c.getString(1) ?: continue
                    types += ct
                    if (ct == "text/plain") {
                        val t = c.getString(2) ?: runCatching {
                            cr.openInputStream(Uri.parse("content://mms/part/${c.getLong(0)}"))?.use { it.readNBytes(SmsWire.MAX_BODY * 4).toString(Charsets.UTF_8) }
                        }.getOrNull()
                        if (t != null) texts += t
                    }
                }
            }
        }
        var from = ""
        if (!m.out) runCatching {
            cr.query(Uri.parse("content://mms/$mmsId/addr"), arrayOf("address", "type"), "type = 137", null, null)?.use { c ->
                if (c.moveToFirst()) from = c.getString(0) ?: ""
            }
        }
        return m.copy(body = SmsWire.mmsBody(texts, types), from = from)
    }
}
