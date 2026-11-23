package com.mydroid.android.contacts

import android.Manifest
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.ContactsContract
import android.provider.ContactsContract.CommonDataKinds.Phone as PH
import android.telephony.PhoneNumberUtils
import android.util.Base64
import android.util.LruCache
import com.mydroid.android.Perms
import com.mydroid.protocol.PhoneKey
import java.io.ByteArrayOutputStream
import java.util.Locale

/**
 * Contact name and photo for a phone number through `PhoneLookup`, cached for a while (the cache is cheap to
 * lose; contacts change rarely). Never logs numbers or names.
 */
class ContactLookup(private val ctx: Context) {
    class Info(val name: String?, val avatar: String?)
    private class Entry(val info: Info, val at: Long, val hasPhoto: Boolean)

    private val cache = LruCache<String, Entry>(400)

    private fun canRead() = Perms.granted(ctx, Manifest.permission.READ_CONTACTS)

    /** Contact name for [number], or null. Alphanumeric sender ids and unreadable contacts give null. */
    fun name(number: String): String? = info(number, withPhoto = false).name

    /** Name, or the number formatted for the locale. Always something to show. */
    fun label(number: String): String = name(number) ?: pretty(number)

    fun info(number: String, withPhoto: Boolean): Info {
        if (number.isBlank() || number.any { it.isLetter() } || !canRead()) return Info(null, null)
        val key = PhoneKey.of(number)
        val now = System.currentTimeMillis()
        cache.get(key)?.let { if (now - it.at < TTL_MS && (!withPhoto || it.hasPhoto)) return it.info }
        val info = try {
            lookup(number, withPhoto)
        } catch (e: Exception) {
            Info(null, null)
        }
        cache.put(key, Entry(info, now, withPhoto))
        return info
    }

    private fun lookup(number: String, withPhoto: Boolean): Info {
        val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
        val proj = arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME, ContactsContract.PhoneLookup.PHOTO_THUMBNAIL_URI)
        var name: String? = null
        var photo: String? = null
        ctx.contentResolver.query(uri, proj, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                name = c.getString(0)?.takeIf { it.isNotBlank() }
                if (withPhoto) photo = c.getString(1)?.let { avatar(Uri.parse(it)) }
            }
        }
        return Info(name, photo)
    }

    /** base64 PNG, at most 128 px on the long edge. */
    private fun avatar(uri: Uri): String? = try {
        ctx.contentResolver.openInputStream(uri)?.use { ins ->
            val bmp = BitmapFactory.decodeStream(ins) ?: return null
            val long = maxOf(bmp.width, bmp.height)
            val scaled = if (long > AVATAR_PX) {
                val s = AVATAR_PX.toFloat() / long
                Bitmap.createScaledBitmap(bmp, maxOf(1, (bmp.width * s).toInt()), maxOf(1, (bmp.height * s).toInt()), true)
            } else bmp
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.PNG, 100, out)
            Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
        }
    } catch (e: Exception) {
        null
    }

    fun pretty(number: String): String {
        if (number.isBlank()) return ""
        if (number.any { it.isLetter() }) return number
        return runCatching { PhoneNumberUtils.formatNumber(number, Locale.getDefault().country) }.getOrNull()?.takeIf { it.isNotBlank() } ?: number
    }

    // ---- Resolving a notification's sender to one phone number (PROTOCOL.md 13.1). Never logs names, numbers or addresses.

    /** How a sender is identified: a contact's exact display name, an email address, or a `Person.uri`/key that points at a contact. */
    enum class By { NAME, EMAIL, URI, LOOKUP_KEY }

    /**
     * The one phone number of the one contact that [by]/[value] identify, normalised by [normalize] (null = can't be sure),
     * or null when the contact is missing or ambiguous: two matching contacts, two different numbers, or a number
     * [normalize] can't vouch for. Blocking; call it from a worker thread.
     */
    fun uniquePhone(by: By, value: String, normalize: (String) -> String?): String? {
        if (value.isBlank() || !canRead()) return null
        return try {
            val ids = when (by) {
                By.NAME -> idsByName(value.trim())
                By.EMAIL -> idsByEmail(value.trim())
                By.URI -> idsByUri(Uri.parse(value))
                By.LOOKUP_KEY -> idsByUri(Uri.withAppendedPath(ContactsContract.Contacts.CONTENT_LOOKUP_URI, Uri.encode(value)))
            }
            if (ids.size != 1) return null
            val numbers = phonesOf(ids.first())
            val norm = numbers.map { normalize(it) }
            if (norm.any { it == null }) return null
            norm.filterNotNull().distinct().singleOrNull()
        } catch (e: Exception) {
            null
        }
    }

    private fun idsByName(name: String): List<Long> {
        val uri = Uri.withAppendedPath(ContactsContract.Contacts.CONTENT_FILTER_URI, Uri.encode(name))
        val out = LinkedHashSet<Long>()
        ctx.contentResolver.query(uri, arrayOf(ContactsContract.Contacts._ID, ContactsContract.Contacts.DISPLAY_NAME), null, null, null)?.use { c ->
            var n = 0
            while (c.moveToNext() && n++ < 30) if (c.getString(1)?.trim().equals(name, ignoreCase = true)) out.add(c.getLong(0))
        }
        return out.toList()
    }

    private fun idsByEmail(email: String): List<Long> {
        val uri = Uri.withAppendedPath(ContactsContract.CommonDataKinds.Email.CONTENT_LOOKUP_URI, Uri.encode(email))
        val out = LinkedHashSet<Long>()
        ctx.contentResolver.query(uri, arrayOf(ContactsContract.CommonDataKinds.Email.CONTACT_ID), null, null, null)?.use { c ->
            var n = 0
            while (c.moveToNext() && n++ < 10) out.add(c.getLong(0))
        }
        return out.toList()
    }

    private fun idsByUri(uri: Uri): List<Long> {
        if (uri.scheme != "content" || uri.authority != ContactsContract.AUTHORITY) return emptyList()
        val resolved = ContactsContract.Contacts.lookupContact(ctx.contentResolver, uri) ?: return emptyList()
        return listOf(android.content.ContentUris.parseId(resolved))
    }

    private fun phonesOf(contactId: Long): List<String> {
        val out = LinkedHashSet<String>()
        ctx.contentResolver.query(PH.CONTENT_URI, arrayOf(PH.NUMBER, PH.NORMALIZED_NUMBER), "${PH.CONTACT_ID} = ?", arrayOf(contactId.toString()), null)?.use { c ->
            var n = 0
            while (c.moveToNext() && n++ < 20) {
                // The provider's own E.164 (it knew the contact's country) beats us guessing from the raw text.
                val v = c.getString(1)?.takeIf { it.startsWith("+") } ?: c.getString(0)
                if (!v.isNullOrBlank()) out.add(v)
            }
        }
        return out.toList()
    }

    private companion object {
        const val TTL_MS = 10 * 60_000L
        const val AVATAR_PX = 128
    }
}
