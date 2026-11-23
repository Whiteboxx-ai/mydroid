package com.mydroid.android.notif

import android.app.Notification
import android.content.Context
import android.os.Bundle
import android.telephony.TelephonyManager
import android.util.LruCache
import androidx.core.app.NotificationCompat
import com.mydroid.android.contacts.ContactLookup
import com.mydroid.protocol.PhoneE164
import com.mydroid.protocol.TelUri

/**
 * Who a notification is from (`notif.posted.person`, PROTOCOL.md 13.1) and their phone number when that can be
 * known for sure. Contact lookups are cached (hits and misses). Never logs names or numbers. Worker thread only.
 */
class NotifPeople(private val ctx: Context) {
    class Who(val name: String, val phone: String?)

    private class Entry(val phone: String?, val at: Long)

    private val contacts = ContactLookup(ctx)
    private val cache = LruCache<String, Entry>(200)

    /**
     * The country national numbers are read in: the network country, or the SIM's when there's no network. While
     * roaming (the two differ) a number without `+` could be either country's, so there is no answer.
     */
    private fun region(): String? {
        val tm = ctx.getSystemService(TelephonyManager::class.java) ?: return null
        val net = runCatching { tm.networkCountryIso }.getOrNull().orEmpty()
        val sim = runCatching { tm.simCountryIso }.getOrNull().orEmpty()
        if (net.isNotBlank() && sim.isNotBlank() && !net.equals(sim, true)) return null
        return net.ifBlank { sim }.ifBlank { null }
    }

    private fun e164(raw: String): String? = PhoneE164.normalize(raw, region())

    private fun cached(key: String, compute: () -> String?): String? {
        val now = System.currentTimeMillis()
        cache.get(key)?.let { if (now - it.at < TTL_MS) return it.phone }
        val v = try { compute() } catch (e: Exception) { null }
        cache.put(key, Entry(v, now))
        return v
    }

    private fun phoneOfName(name: String): String? =
        if (name.isBlank()) null else cached("n:${name.lowercase()}") { contacts.uniquePhone(ContactLookup.By.NAME, name, ::e164) }

    /** The sender's number from `Person.uri` (`tel:`, `mailto:`, a contact URI), `Person.key` or, last, their name. */
    private fun phoneOfPerson(uri: String?, key: String?, name: String?): String? {
        TelUri.number(uri)?.let { raw -> e164(raw)?.let { return it } }
        val u = uri?.trim().orEmpty()
        if (u.startsWith("mailto:", true)) {
            val addr = u.substring(7).substringBefore('?').trim()
            cached("m:${addr.lowercase()}") { contacts.uniquePhone(ContactLookup.By.EMAIL, addr, ::e164) }?.let { return it }
        } else if (u.startsWith("content://")) {
            cached("u:$u") { contacts.uniquePhone(ContactLookup.By.URI, u, ::e164) }?.let { return it }
        }
        if (!key.isNullOrBlank() && key.length < 200 && key.none { it == '|' || it.isWhitespace() }) {
            cached("k:$key") { contacts.uniquePhone(ContactLookup.By.LOOKUP_KEY, key, ::e164) }?.let { return it }
        }
        return name?.let(::phoneOfName)
    }

    /**
     * [style] present: the last message that isn't the user's own decides. In a group the sender is named but no
     * number is given (a group chat link must not turn into a DM with whoever spoke last).
     * No style: `EXTRA_PEOPLE_LIST` with exactly one person, else, for message notifications, the title.
     */
    fun resolve(style: NotificationCompat.MessagingStyle?, ex: Bundle, title: String?, isMessage: Boolean, isGroup: Boolean): Who? {
        if (style != null) {
            val userKey = style.user.key
            val m = style.messages.lastOrNull { msg ->
                val p = msg.person
                !((p == null && msg.sender == null) || (userKey != null && p?.key == userKey))
            }
            val p = m?.person
            val name = (p?.name ?: m?.sender)?.toString()?.takeIf { it.isNotBlank() }
            if (m != null && name != null) {
                return Who(name, if (isGroup) null else phoneOfPerson(p?.uri, p?.key, name))
            }
        }
        @Suppress("DEPRECATION")
        val people = try { ex.getParcelableArrayList<android.app.Person>(Notification.EXTRA_PEOPLE_LIST) } catch (e: Exception) { null }
        if (people != null && people.size == 1) {
            val p = people[0]
            val name = p.name?.toString()?.takeIf { it.isNotBlank() }
            if (name != null) return Who(name, if (isGroup) null else phoneOfPerson(p.uri, p.key, name))
        }
        if (isMessage && !isGroup && !title.isNullOrBlank()) {
            // SMS from an unsaved number is titled with the number itself.
            if (PhoneE164.looksLikeNumber(title)) return Who(title, e164(title))
            return Who(title, phoneOfName(title))
        }
        return null
    }

    private companion object { const val TTL_MS = 10 * 60_000L }
}
