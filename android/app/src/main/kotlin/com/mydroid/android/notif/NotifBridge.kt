package com.mydroid.android.notif

import android.app.Notification
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.Icon
import android.provider.Telephony
import android.util.Log
import com.mydroid.protocol.MarkRead
import com.mydroid.protocol.NotifFields
import com.mydroid.protocol.NotifLinks
import com.mydroid.protocol.NotifOpen
import com.mydroid.protocol.MuteTracker
import com.mydroid.protocol.OtpParser
import com.mydroid.protocol.Redaction
import com.mydroid.protocol.SmsCache
import com.mydroid.protocol.SmsEntry
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.service.notification.StatusBarNotification
import android.util.Base64
import android.util.LruCache
import androidx.core.app.NotificationCompat
import com.mydroid.protocol.Message
import kotlinx.serialization.json.*
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap

/**
 * Turns Android notifications into `notif.*` messages and executes `notif.reply/action/dismiss`.
 * Owned by the ConnectionManager; the NotificationListenerService just feeds it events.
 */
class NotifBridge(
    private val ctx: Context,
    private val send: (Message) -> Boolean,
    private val enabled: () -> Boolean,
) {
    @Volatile var listener: MydroidNotificationListener? = null
        set(v) {
            field = v
            mediaProbe.setListener(if (v != null) android.content.ComponentName(ctx, MydroidNotificationListener::class.java) else null)
        }
    private val lastSent = ConcurrentHashMap<String, Int>()
    private val labelCache = ConcurrentHashMap<String, String>()
    private val iconCache = LruCache<String, String>(64)
    private val avatarCache = LruCache<String, String>(48)

    /** All the describing/encoding happens here, never on the listener's main thread. */
    private val exec = Executors.newSingleThreadScheduledExecutor { Thread(it, "mydroid-notif").apply { isDaemon = true } }
    /** Latest sbn per key waiting out the debounce window. */
    private val debounce = ConcurrentHashMap<String, StatusBarNotification>()

    private val people = NotifPeople(ctx)
    /** Spotify check and media-session metadata. Declared before [listener] is ever set. */
    val mediaProbe = MediaIdProbe(ctx)
    private val opener = NotifOpener(ctx, exec, ::appLabel)

    @Volatile private var smsPkg: String? = null
    @Volatile private var smsPkgAt = 0L

    fun resetSent() = lastSent.clear()

    // ------------------------------------------------------------ muted apps (PROTOCOL.md 7.2)

    private val mutes = MuteTracker()

    /** Filter at the source, and withdraw what the Mac is already showing for newly muted apps. */
    fun setMuted(pkgs: Set<String>) {
        val withdraw = mutes.update(pkgs)
        for (key in withdraw) {
            debounce.remove(key); lastSent.remove(key)
            if (enabled()) send(Message.of("notif.removed") { put("key", key) })
        }
        if (withdraw.isNotEmpty()) Log.i(TAG, "muted apps=${pkgs.size} withdrew=${withdraw.size}")
    }

    // ------------------------------------------------------------ SMS recovery (Android 15+ redacts OTP notifications)

    private val smsCache = SmsCache()

    /** The system's localized "Sensitive notification content hidden", falling back to the English text. */
    private val redactedMarkers: List<String> by lazy {
        val res = android.content.res.Resources.getSystem()
        listOfNotNull(
            runCatching {
                val id = res.getIdentifier("redacted_notification_message", "string", "android")
                if (id != 0) res.getString(id) else null
            }.getOrNull(),
            Redaction.ENGLISH,
        )
    }

    private fun isRedacted(t: CharSequence?) = Redaction.isRedacted(t, redactedMarkers)

    private fun contactName(address: String): String? = try {
        if (!com.mydroid.android.Perms.granted(ctx, android.Manifest.permission.READ_CONTACTS)) null
        else ctx.contentResolver.query(
            Uri.withAppendedPath(android.provider.ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(address)),
            arrayOf(android.provider.ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null,
        )?.use { if (it.moveToFirst()) it.getString(0) else null }
    } catch (e: Exception) {
        null
    }

    /** From SmsOtpReceiver. Text and code are kept in memory for ~2 min and never logged. */
    fun onSms(address: String, body: String, at: Long) {
        if (!enabled()) return
        exec.execute {
            val aliases = if (address.any { it.isLetter() }) emptyList() else listOfNotNull(contactName(address))
            val entry = SmsEntry(address, body, at, OtpParser.parse(body, address), aliases)
            smsCache.add(entry)
            Log.i(TAG, "sms cached len=${body.length} otp=${entry.otp != null}")
            // The notification may already be up (redacted): re-send it with the real text.
            try {
                val smsPackage = defaultSmsPackage()
                listener?.activeNotifications?.filter { it.packageName == smsPackage }?.forEach { sbn ->
                    val ex = sbn.notification.extras
                    if (!skip(sbn) && (isRedacted(ex?.getCharSequence(Notification.EXTRA_TEXT)) ||
                            isRedacted(ex?.getCharSequence(Notification.EXTRA_BIG_TEXT)))) {
                        lastSent.remove(sbn.key)
                        onPosted(sbn)
                    }
                }
            } catch (_: Exception) {
            }
            if (entry.otp != null) exec.schedule({ deliverIfUnclaimed(entry) }, 3, TimeUnit.SECONDS)
        }
    }

    /** No notification carried this code within ~3 s (hidden, grouped, muted): post it ourselves. */
    private fun deliverIfUnclaimed(e: SmsEntry) {
        if (e.consumed || !enabled()) return
        e.consumed = true
        val otp = e.otp ?: return
        val pkg = defaultSmsPackage() ?: "com.android.messaging"
        if (mutes.isMuted(pkg)) return
        val app = appLabel(pkg)
        val sender = e.aliases.firstOrNull() ?: e.address
        val key = "sms-otp:${e.at}"
        val body = buildJsonObject {
            put("key", key); put("pkg", pkg); put("app", app)
            put("title", sender); put("text", e.body); put("when", e.at)
            put("canReply", false); put("actions", JsonArray(emptyList()))
            put("category", "message")
            put("conversation", buildJsonObject {
                put("title", sender); put("isGroup", false)
                put("messages", JsonArray(listOf(buildJsonObject { put("sender", sender); put("text", e.body); put("when", e.at) })))
            })
            put("otp", buildJsonObject { put("code", otp.code); put("source", sender) })
            iconFor(pkg)?.let { put("icon", it) }
        }
        send(Message(JsonObject(mapOf("t" to JsonPrimitive("notif.posted")) + body)))
        Log.i(TAG, "sms-otp synthetic posted app=$app")
        exec.schedule({ if (enabled()) send(Message.of("notif.removed") { put("key", key) }) }, 10, TimeUnit.MINUTES)
    }

    /**
     * Debounced ~300 ms per key: the first post schedules a send, later updates to the same key inside
     * the window only replace the pending sbn, so chatty apps cost one encode and one frame.
     */
    fun onPosted(sbn: StatusBarNotification) {
        // The Spotify check runs whether or not notifications are mirrored; it only logs fixed labels.
        if (sbn.packageName == MediaIdProbe.SPOTIFY && (MediaIdProbe.tokenOf(sbn.notification) != null || sbn.notification.category == Notification.CATEGORY_TRANSPORT)) {
            mediaProbe.onNotification(sbn.notification)
        }
        if (!enabled()) return
        if (mutes.isMuted(sbn.packageName)) { Log.i(TAG, "notif muted, not forwarded pkg=${sbn.packageName}"); return }
        if (skip(sbn)) return
        if (debounce.put(sbn.key, sbn) == null) {
            exec.schedule({ debounce.remove(sbn.key)?.let(::process) }, DEBOUNCE_MS, TimeUnit.MILLISECONDS)
        }
    }

    private fun process(sbn: StatusBarNotification) {
        if (!enabled()) return
        val body = try {
            describe(sbn)
        } catch (e: Exception) {
            Log.w(TAG, "describe failed pkg=${sbn.packageName}", e); null
        } ?: return
        val h = body.toString().hashCode()
        mutes.sent(sbn.key, sbn.packageName)
        if (lastSent.put(sbn.key, h) == h) return // nothing visible changed
        send(Message(JsonObject(mapOf("t" to JsonPrimitive("notif.posted")) + body)))
        Log.i(TAG, "notif.posted pkg=${sbn.packageName} app=${body["app"]?.jsonPrimitive?.content} cat=${body["category"]?.jsonPrimitive?.content} " +
            "conv=${body["conversation"] != null} otp=${body["otp"] != null} icon=${body["icon"] != null} " +
            "titleLen=${body["title"]?.jsonPrimitive?.content?.length} textLen=${body["text"]?.jsonPrimitive?.content?.length} actions=${(body["actions"] as? JsonArray)?.size}")
    }

    fun onRemoved(sbn: StatusBarNotification) {
        debounce.remove(sbn.key)
        lastSent.remove(sbn.key)
        mutes.forget(sbn.key)
        if (!enabled()) return
        send(Message.of("notif.removed") { put("key", sbn.key) })
    }

    /** Whole current list, for `notif.snapshot` on connect. */
    fun snapshot(): Message {
        lastSent.clear()
        val items = if (!enabled()) emptyList() else {
            val active = try {
                listener?.activeNotifications?.toList() ?: emptyList()
            } catch (e: SecurityException) {
                emptyList()
            }
            active.mapNotNull { sbn -> describe(sbn)?.also { lastSent[sbn.key] = it.toString().hashCode(); mutes.sent(sbn.key, sbn.packageName) } }
        }
        return Message.of("notif.snapshot") { put("items", JsonArray(items)) }
    }

    private fun skip(sbn: StatusBarNotification): Boolean {
        val n = sbn.notification
        if (sbn.packageName == ctx.packageName) return true
        if (mutes.isMuted(sbn.packageName)) return true
        if (n.flags and Notification.FLAG_ONGOING_EVENT != 0) return true
        if (n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return true
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return true
        if (n.category == Notification.CATEGORY_TRANSPORT) return true
        if (n.extras?.containsKey(Notification.EXTRA_MEDIA_SESSION) == true) return true
        return false
    }

    private fun replyAction(n: Notification): Notification.Action? =
        n.actions?.firstOrNull { a -> a.remoteInputs?.any { it.allowFreeFormInput } == true }

    private fun defaultSmsPackage(): String? {
        val now = System.currentTimeMillis()
        if (now - smsPkgAt > 5 * 60_000) {
            smsPkg = runCatching { Telephony.Sms.getDefaultSmsPackage(ctx) }.getOrNull()
            smsPkgAt = now
        }
        return smsPkg
    }

    fun describe(sbn: StatusBarNotification): JsonObject? {
        if (skip(sbn)) return null
        val n = sbn.notification
        val ex = n.extras ?: Bundle()
        val pkg = sbn.packageName
        val app = appLabel(pkg, n)
        var title = ex.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        var text = (ex.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: ex.getCharSequence(Notification.EXTRA_TEXT))?.toString()
        val style = runCatching { NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n) }.getOrNull()
        val isMessage = style != null || n.category == Notification.CATEGORY_MESSAGE || pkg == defaultSmsPackage()
        var conversation: JsonObject? = null
        if (style != null) {
            style.messages.lastOrNull()?.let { last ->
                text = last.text?.toString() ?: text
                val who = style.conversationTitle?.toString() ?: last.person?.name?.toString()
                if (!who.isNullOrBlank()) title = who
            }
        }
        if (title.isNullOrBlank() && text.isNullOrBlank()) return null
        // Android can redact the short text while leaving a different value in the expanded text.
        val marker = listOf(text, ex.getCharSequence(Notification.EXTRA_TEXT), ex.getCharSequence(Notification.EXTRA_BIG_TEXT))
            .firstOrNull(::isRedacted)
        val redacted = marker != null
        val fromSmsApp = pkg == defaultSmsPackage()
        val sms = if (fromSmsApp) {
            smsCache.find(listOfNotNull(title, style?.conversationTitle?.toString()), System.currentTimeMillis(), lenient = redacted)
                ?.takeIf { redacted || it.body.trim() == text?.trim() }
                ?.also { it.consumed = true }
        } else null
        if (redacted) {
            text = sms?.body ?: marker.toString()
            title = sms?.aliases?.firstOrNull() ?: sms?.address ?: app
        }
        if (isMessage && (!redacted || sms != null)) {
            conversation = conversationOf(sbn, style.takeUnless { redacted }, title ?: "", text ?: "")
        }
        val reply = replyAction(n)
        val actions = n.actions.orEmpty().withIndex()
            .filter { (_, a) -> a !== reply && !a.title.isNullOrBlank() }
            .map { (i, a) -> buildJsonObject { put("index", i); put("title", a.title.toString()) } }
        // OTP: scan the newest message (or the plain text) plus title. Source = sender / conversation / app.
        val source = if (isMessage) (conversation?.get("title")?.jsonPrimitive?.content ?: title ?: app) else app
        val otp = if (redacted) sms?.otp?.copy(source = source) else OtpParser.parse(listOfNotNull(title, text).joinToString("\n"), source)
        return buildJsonObject {
            put("key", sbn.key); put("pkg", pkg); put("app", app)
            put("title", title ?: ""); put("text", text ?: "")
            put("when", if (n.`when` > 0) n.`when` else sbn.postTime)
            put("canReply", reply != null)
            put("actions", JsonArray(actions))
            put("markRead", n.actions.orEmpty().any(::isMarkRead))
            put("category", if (isMessage) "message" else "other")
            conversation?.let { put("conversation", it) }
            if (otp != null) put("otp", buildJsonObject { put("code", otp.code); put("source", otp.source.ifBlank { app }) })
            iconFor(pkg)?.let { put("icon", it) }
            if (redacted) return@buildJsonObject
            // PROTOCOL.md 13.1: what the Mac needs to open this somewhere useful. All optional.
            val isGroup = style?.isGroupConversation == true
            people.resolve(style, ex, title, isMessage, isGroup)?.let { put("person", NotifFields.person(it.name, it.phone)) }
            val links = NotifLinks.extract(
                listOf(text, ex.getCharSequence(Notification.EXTRA_BIG_TEXT), ex.getCharSequence(Notification.EXTRA_TEXT)) +
                    (style?.messages?.takeLast(5)?.reversed()?.map { it.text } ?: emptyList()) + listOf(title),
            )
            if (links.isNotEmpty()) put("links", NotifFields.links(links))
            if (MediaIdProbe.tokenOf(n) != null) mediaProbe.metaOf(n)?.let { put("media", NotifFields.media(it.title, it.artist, it.album, it.mediaId)) }
        }
    }

    private fun conversationOf(sbn: StatusBarNotification, style: NotificationCompat.MessagingStyle?, title: String, text: String): JsonObject {
        val n = sbn.notification
        val userKey = style?.user?.key
        val msgs = if (style != null && style.messages.isNotEmpty()) {
            val last5 = style.messages.takeLast(5)
            last5.map { m ->
                val p = m.person
                val mine = (p == null && m.sender == null) || (userKey != null && p?.key == userKey)
                val name = (p?.name ?: m.sender)?.toString().orEmpty()
                val t = m.text?.toString().orEmpty()
                Triple(if (mine) "" else name, t, m.timestamp)
            }
        } else {
            listOf(Triple(title, text, if (n.`when` > 0) n.`when` else sbn.postTime))
        }
        val group = style?.isGroupConversation == true
        val convTitle = style?.conversationTitle?.toString()?.takeIf { it.isNotBlank() } ?: title
        val avatar = avatarFor(sbn, style, group, convTitle)
        return buildJsonObject {
            put("title", convTitle); put("isGroup", group)
            put("messages", JsonArray(msgs.map { (who, t, w) ->
                buildJsonObject { put("sender", who); put("text", t); put("when", w) }
            }))
            avatar?.let { put("avatar", it) }
        }
    }

    /** Group icon or the last sender's person icon, falling back to the large icon. Cached per package + conversation. */
    private fun avatarFor(sbn: StatusBarNotification, style: NotificationCompat.MessagingStyle?, group: Boolean, convTitle: String): String? {
        val n = sbn.notification
        val last = style?.messages?.lastOrNull()?.person
        val cacheKey = "${sbn.packageName}|${if (group) convTitle else (last?.key ?: last?.name ?: convTitle)}"
        avatarCache.get(cacheKey)?.let { return it.ifEmpty { null } }
        val b64 = try {
            val icon: Icon? = if (group) n.getLargeIcon() ?: last?.icon?.toIcon(ctx)
            else last?.icon?.toIcon(ctx) ?: n.getLargeIcon()
            icon?.loadDrawable(ctx)?.let { encode(it, AVATAR_PX) }
        } catch (e: Exception) {
            null
        } ?: ""
        avatarCache.put(cacheKey, b64)
        return b64.ifEmpty { null }
    }

    /** Needs package visibility: `<queries>` for LAUNCHER apps plus QUERY_ALL_PACKAGES (sideloaded build). */
    private fun appLabel(pkg: String, n: Notification? = null): String {
        labelCache[pkg]?.let { return it }
        return try {
            val pm = ctx.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString().also { labelCache[pkg] = it }
        } catch (e: Exception) {
            // Not cached: visibility may change. The system-provided name override is the next best thing.
            n?.extras?.getString("android.substName")?.takeIf { it.isNotBlank() } ?: pkg
        }
    }

    private fun iconFor(pkg: String): String? {
        iconCache.get(pkg)?.let { return it.ifEmpty { null } }
        val b64 = try {
            encode(ctx.packageManager.getApplicationIcon(pkg), 96)
        } catch (e: Exception) {
            ""
        }
        iconCache.put(pkg, b64)
        return b64.ifEmpty { null }
    }

    /** Drawable to base64 PNG no larger than [maxPx] on its longest side. */
    private fun encode(d: Drawable, maxPx: Int): String {
        val bmp = toBitmap(d, maxPx)
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }

    private fun toBitmap(d: Drawable, px: Int): Bitmap {
        val w0 = d.intrinsicWidth.takeIf { it > 0 } ?: px
        val h0 = d.intrinsicHeight.takeIf { it > 0 } ?: px
        val scale = minOf(1f, px.toFloat() / maxOf(w0, h0))
        val w = maxOf(1, (w0 * scale).toInt())
        val h = maxOf(1, (h0 * scale).toInt())
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        val src = (d as? BitmapDrawable)?.bitmap
        if (src != null && src.config == Bitmap.Config.HARDWARE) {
            // Software canvases can't draw hardware bitmaps; copy first.
            val sw = src.copy(Bitmap.Config.ARGB_8888, false)
            c.drawBitmap(sw, null, android.graphics.Rect(0, 0, w, h), null)
        } else {
            d.setBounds(0, 0, w, h)
            d.draw(c)
        }
        return bmp
    }

    private fun find(key: String): StatusBarNotification? = try {
        listener?.activeNotifications?.firstOrNull { it.key == key }
    } catch (e: SecurityException) {
        null
    }

    /** Fires the RemoteInput reply. Returns an error string, or null on success. */
    fun reply(key: String, text: String): String? {
        val sbn = find(key) ?: return "That notification is gone"
        val action = replyAction(sbn.notification) ?: return "This notification can't be replied to"
        return try {
            val inputs = action.remoteInputs!!
            val results = Bundle()
            for (ri in inputs) results.putCharSequence(ri.resultKey, text)
            val intent = Intent()
            RemoteInput.addResultsToIntent(inputs, intent, results)
            action.actionIntent.send(ctx, 0, intent)
            null
        } catch (e: Exception) {
            e.message ?: "Couldn't send the reply"
        }
    }

    fun fireAction(key: String, index: Int): String? {
        val sbn = find(key) ?: return "That notification is gone"
        val a = sbn.notification.actions?.getOrNull(index) ?: return "No such action"
        return try {
            a.actionIntent.send()
            null
        } catch (e: Exception) {
            e.message ?: "Couldn't run the action"
        }
    }

    /**
     * `notif.open` (PROTOCOL.md 13.2). Sends the live notification's contentIntent; if it's gone, launches its app
     * (`note:"launched app"`). Replies `notif.result` once; [reply] is for tests and the debug broadcast.
     */
    fun open(key: String, reply: (Message) -> Unit = { send(it) }) {
        exec.execute {
            try {
                val sbn = find(key)
                val pkg = sbn?.packageName ?: NotifOpen.packageOf(key) ?: if (key.startsWith("sms-otp:")) defaultSmsPackage() else null
                opener.open(key, pkg, sbn?.notification?.contentIntent) { r -> reply(NotifOpen.result(key, r.ok, r.error, r.note)) }
            } catch (e: Exception) {
                Log.w(TAG, "notif.open failed: ${e.javaClass.simpleName}")
                reply(NotifOpen.result(key, false, "Couldn't open that on your phone"))
            }
        }
    }

    private fun isMarkRead(a: Notification.Action) = MarkRead.isMarkRead(a.semanticAction, a.title)

    /**
     * `notif.read` (PROTOCOL.md 7.6): the user read this conversation on the Mac. Fires the app's own "mark as read"
     * action (a broadcast or service, so no UI opens; an action that would open an activity is not used). With none
     * to fire, or one that fails, the notification is cancelled instead. Either way `notif.removed` follows from
     * [onRemoved]. Runs on the notif worker, never on the caller's thread.
     */
    fun markRead(key: String) {
        exec.execute {
            val sbn = find(key) ?: return@execute // already gone; notif.removed has gone out
            val pi = sbn.notification.actions?.firstOrNull(::isMarkRead)?.actionIntent
            val fired = pi != null && !(Build.VERSION.SDK_INT >= 31 && pi.isActivity) && try { pi.send(); true } catch (e: Exception) { false }
            Log.i(TAG, "notif.read fired=$fired")
            if (!fired) return@execute dismiss(key)
            // Most apps cancel the notification themselves; if this one only marks its state, take it down too.
            exec.schedule({ if (find(key) != null) dismiss(key) }, 2, TimeUnit.SECONDS)
        }
    }

    fun dismiss(key: String) {
        try {
            listener?.cancelNotification(key)
        } catch (_: Exception) {
        }
    }

    private companion object {
        const val TAG = "MydroidNotif"
        const val DEBOUNCE_MS = 300L
        const val AVATAR_PX = 128
    }
}
