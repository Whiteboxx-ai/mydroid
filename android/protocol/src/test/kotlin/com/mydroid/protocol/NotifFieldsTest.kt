package com.mydroid.protocol

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotifLinksTest {
    private fun links(vararg t: String?) = NotifLinks.extract(t.toList())

    @Test fun plainHttps() = assertEquals(listOf("https://example.com/a?b=1"), links("see https://example.com/a?b=1 now"))
    @Test fun http() = assertEquals(listOf("http://example.com"), links("http://example.com"))
    @Test fun wwwGetsHttps() = assertEquals(listOf("https://www.example.com/x"), links("go to www.example.com/x"))
    @Test fun trailingPunctuation() = assertEquals(listOf("https://example.com/a"), links("Read https://example.com/a."))
    @Test fun trailingCommaAndQuote() = assertEquals(listOf("https://example.com/a"), links("\"https://example.com/a\", then"))
    @Test fun unbalancedParen() = assertEquals(listOf("https://example.com/a"), links("(see https://example.com/a)"))
    @Test fun balancedParenKept() = assertEquals(listOf("https://en.wikipedia.org/wiki/Foo_(bar)"), links("https://en.wikipedia.org/wiki/Foo_(bar)"))
    @Test fun dedupAcrossTexts() = assertEquals(listOf("https://a.com/x"), links("https://a.com/x", "again https://a.com/x"))
    @Test fun atMostThree() = assertEquals(
        listOf("https://a.com", "https://b.com", "https://c.com"),
        links("https://a.com https://b.com https://c.com https://d.com"),
    )
    @Test fun orderFollowsTexts() = assertEquals(listOf("https://b.com", "https://a.com"), links("https://b.com", "https://a.com"))
    @Test fun otherSchemesIgnored() = assertEquals(emptyList<String>(), links("ftp://a.com mailto:x@y.com tg://resolve?x=1 intent://x javascript:alert(1)"))
    @Test fun bareDomainIgnored() = assertEquals(emptyList<String>(), links("meet at example.com tomorrow, file.txt"))
    @Test fun emailIsNotALink() = assertEquals(emptyList<String>(), links("write to me@www.example.com"))
    @Test fun credentialsDropped() = assertEquals(emptyList<String>(), links("https://user:pw@example.com/x"))
    @Test fun noHostDropped() = assertEquals(emptyList<String>(), links("https:// and http://."))
    @Test fun nullsAndBlanks() = assertEquals(emptyList<String>(), links(null, "", "no links here"))
    @Test fun tooLongDropped() = assertEquals(emptyList<String>(), links("https://a.com/" + "x".repeat(2100)))
    @Test fun schemeCaseNormalised() = assertEquals(listOf("https://Example.com/Path"), links("HTTPS://Example.com/Path"))
    @Test fun multiline() = assertEquals(listOf("https://a.com/1", "https://a.com/2"), links("one https://a.com/1\ntwo https://a.com/2"))
}

class PhoneE164Test {
    private fun n(raw: String?, region: String? = "IN") = PhoneE164.normalize(raw, region)

    @Test fun alreadyE164() = assertEquals("+919876543210", n("+919876543210", null))
    @Test fun formattedInternational() = assertEquals("+919876543210", n("+91 98765-43210", null))
    @Test fun indiaNational() = assertEquals("+919876543210", n("98765 43210"))
    @Test fun indiaTrunkZero() = assertEquals("+919876543210", n("098765 43210"))
    @Test fun indiaWithCcNoPlus() = assertEquals("+919876543210", n("919876543210"))
    @Test fun doubleZeroPrefix() = assertEquals("+447911123456", n("00 44 7911 123456", "IN"))
    @Test fun usNational() = assertEquals("+14155552671", n("(415) 555-2671", "US"))
    @Test fun usWithOne() = assertEquals("+14155552671", n("1 415 555 2671", "US"))
    @Test fun usAreaCodeCannotStartWithOne() = assertNull(n("115 555 2671", "US"))
    @Test fun usExitPrefix011() = assertEquals("+919876543210", n("011 91 98765 43210", "US"))
    @Test fun usPlus() = assertEquals("+14155552671", n("+1 (415) 555-2671", null))
    @Test fun usPlusTooShort() = assertNull(n("+1 415 555 267", null))
    @Test fun ukNationalMobile() = assertEquals("+447911123456", n("07911 123456", "GB"))
    @Test fun regionCaseInsensitive() = assertEquals("+447911123456", n("07911 123456", "gb"))
    @Test fun germanyMobile() = assertEquals("+4915123456789", n("0151 23456789", "DE"))
    @Test fun italyKeepsLeadingZero() = assertEquals("+390212345678", n("02 1234 5678", "IT"))
    @Test fun frenchNational() = assertEquals("+33612345678", n("06 12 34 56 78", "FR"))
    @Test fun australiaNational() = assertEquals("+61412345678", n("0412 345 678", "AU"))

    @Test fun noRegionNoGuess() = assertNull(n("9876543210", null))
    @Test fun blankRegionNoGuess() = assertNull(n("9876543210", ""))
    @Test fun unknownRegionNoGuess() = assertNull(n("9876543210", "ZZ"))
    @Test fun wrongLengthNoGuess() = assertNull(n("98765 4321"))
    @Test fun tooLongNoGuess() = assertNull(n("98765432101234"))
    @Test fun shortCodes() { assertNull(n("56767")); assertNull(n("+56767", null)); assertNull(n("100")) }
    @Test fun alphanumericSender() { assertNull(n("HDFCBK")); assertNull(n("AX-HDFCBK")); assertNull(n("+1800FLOWERS", null)) }
    @Test fun unknownCountryCode() = assertNull(n("+800 1234 5678", null))
    @Test fun plusInMiddle() = assertNull(n("91+9876543210", null))
    @Test fun allSameDigits() = assertNull(n("+11111111111", null))
    @Test fun emptyAndNull() { assertNull(n("")); assertNull(n("   ")); assertNull(n(null)) }
    @Test fun extensionDropped() = assertEquals("+14155552671", n("+1 415 555 2671 ext. 22", null))
    @Test fun extensionSemicolon() = assertEquals("+14155552671", n("+14155552671;ext=22", null))
    @Test fun garbageInside() = assertNull(n("98765*43210"))

    @Test fun looksLikeNumber() {
        assertTrue(PhoneE164.looksLikeNumber("+91 98765 43210"))
        assertTrue(PhoneE164.looksLikeNumber("(415) 555-2671"))
        assertFalse(PhoneE164.looksLikeNumber("Mom"))
        assertFalse(PhoneE164.looksLikeNumber("HDFCBK"))
        assertFalse(PhoneE164.looksLikeNumber("56767"))
        assertFalse(PhoneE164.looksLikeNumber(null))
    }

    @Test fun telUri() {
        assertEquals("+919876543210", TelUri.number("tel:+919876543210"))
        assertEquals("+91 98765 43210", TelUri.number("tel:%2B91%2098765%2043210"))
        assertEquals("+919876543210", TelUri.number("TEL:+919876543210;ext=5"))
        assertNull(TelUri.number("mailto:a@b.com"))
        assertNull(TelUri.number("tel:"))
        assertNull(TelUri.number(null))
        assertEquals("+919876543210", PhoneE164.normalize(TelUri.number("tel:%2B919876543210"), null))
    }
}

class MediaIdsTest {
    private val track = "spotify:track:6rqhFgbbKwnb9MLmUQDhG6"

    @Test fun spotifyTrack() = assertEquals(track, MediaIds.filter(track))
    @Test fun spotifyEpisode() = assertEquals("spotify:episode:512ojhOuo1ktJprKbVcKyQ", MediaIds.filter("spotify:episode:512ojhOuo1ktJprKbVcKyQ"))
    @Test fun httpsUrl() = assertEquals("https://open.spotify.com/track/abc", MediaIds.filter(" https://open.spotify.com/track/abc "))
    @Test fun httpUrl() = assertEquals("http://example.com/a", MediaIds.filter("http://example.com/a"))
    @Test fun otherSpotifyKindsRefused() { assertNull(MediaIds.filter("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M")); assertNull(MediaIds.filter("spotify:user:xyz")) }
    @Test fun spotifyIdMustLookRight() { assertNull(MediaIds.filter("spotify:track:")); assertNull(MediaIds.filter("spotify:track:abc")); assertNull(MediaIds.filter("spotify:track:6rqhFgbbKwnb9MLm UQDhG6")) }
    @Test fun contentUriRefused() { assertNull(MediaIds.filter("content://media/external/audio/media/42")); assertNull(MediaIds.filter("file:///sdcard/a.mp3")) }
    @Test fun opaqueIdRefused() { assertNull(MediaIds.filter("1234567")); assertNull(MediaIds.filter("")); assertNull(MediaIds.filter(null)) }
    @Test fun urlWithCredentialsRefused() = assertNull(MediaIds.filter("https://u:p@example.com/x"))
    @Test fun urlWithSpacesRefused() = assertNull(MediaIds.filter("https://example.com/a b"))
    @Test fun urlWithoutHostRefused() = assertNull(MediaIds.filter("https:///x"))

    @Test fun schemeLabels() {
        assertEquals("spotify:track", MediaIds.scheme(track))
        assertEquals("spotify:episode", MediaIds.scheme("spotify:episode:512ojhOuo1ktJprKbVcKyQ"))
        assertEquals("http", MediaIds.scheme("https://x.y/z"))
        assertEquals("other", MediaIds.scheme("content://foo"))
        assertEquals("other", MediaIds.scheme("12345"))
        assertEquals("none", MediaIds.scheme(null))
        assertEquals("none", MediaIds.scheme("  "))
    }

    @Test fun pickPrefersMediaId() {
        val p = MediaIds.pick(track, "https://open.spotify.com/track/x")
        assertEquals(track, p.id); assertEquals(MediaIds.Field.MEDIA_ID, p.field)
    }
    @Test fun pickFallsBackToUri() {
        val p = MediaIds.pick("opaque-123", track)
        assertEquals(track, p.id); assertEquals("spotify:track", p.scheme); assertEquals(MediaIds.Field.MEDIA_URI, p.field)
    }
    @Test fun pickNothingUsable() {
        val p = MediaIds.pick("opaque-123", null)
        assertNull(p.id); assertEquals("other", p.scheme); assertEquals(MediaIds.Field.MEDIA_ID, p.field)
        val none = MediaIds.pick(null, "")
        assertNull(none.id); assertEquals("none", none.scheme); assertEquals(MediaIds.Field.NONE, none.field)
    }

    @Test fun logLineNeverContainsTheId() {
        val line = MediaIds.pick(track, null).logLine()
        assertEquals("spotify-mediaid present=true scheme=spotify:track field=MEDIA_ID", line)
        assertFalse(line.contains("6rqh"))
        assertEquals("spotify-mediaid present=false scheme=none field=none", MediaIds.pick(null, null).logLine())
        assertEquals("spotify-mediaid present=false scheme=other field=MEDIA_URI", MediaIds.pick("", "content://secret/title").logLine())
        assertFalse(MediaIds.pick("", "content://secret/title").logLine().contains("secret"))
    }
}

class NotifFieldsCodecTest {
    private fun roundTrip(m: Message): Message = Codec.decode(Codec.encode(m))

    @Test fun notifPostedWithAllNewFields() {
        val m = Message(JsonObject(mapOf(
            "t" to JsonPrimitive("notif.posted"), "key" to JsonPrimitive("0|com.whatsapp|1|null|10"),
            "pkg" to JsonPrimitive("com.whatsapp"), "title" to JsonPrimitive("Asha"), "text" to JsonPrimitive("look https://example.com/x"),
            "person" to NotifFields.person("Asha", "+919876543210"),
            "links" to NotifFields.links(listOf("https://example.com/x")),
            "media" to NotifFields.media("Song", "Artist", "Album", "spotify:track:6rqhFgbbKwnb9MLmUQDhG6"),
        )))
        val r = roundTrip(m)
        assertEquals("notif.posted", r.type)
        val p = r.obj("person")!!
        assertEquals("Asha", p["name"]!!.jsonPrimitive.content)
        assertEquals("+919876543210", p["phone"]!!.jsonPrimitive.content)
        assertEquals(listOf("https://example.com/x"), r.arr("links")!!.map { it.jsonPrimitive.content })
        val md = r.obj("media")!!
        assertEquals("Song", md["title"]!!.jsonPrimitive.content)
        assertEquals("Artist", md["artist"]!!.jsonPrimitive.content)
        assertEquals("Album", md["album"]!!.jsonPrimitive.content)
        assertEquals("spotify:track:6rqhFgbbKwnb9MLmUQDhG6", md["mediaId"]!!.jsonPrimitive.content)
    }

    @Test fun optionalPartsAreOmitted() {
        val p = NotifFields.person("Asha", null)
        assertFalse(p.containsKey("phone"))
        val md = NotifFields.media("T", "A", null, null)
        assertFalse(md.containsKey("album")); assertFalse(md.containsKey("mediaId"))
        assertFalse(NotifFields.media("T", "A", "", null).containsKey("album"))
        assertEquals(0, NotifFields.links(emptyList()).size)
    }

    @Test fun snapshotItemsKeepTheFields() {
        val item = JsonObject(mapOf("key" to JsonPrimitive("k"), "person" to NotifFields.person("A", "+14155552671"), "links" to NotifFields.links(listOf("https://a.com"))))
        val r = roundTrip(Message.of("notif.snapshot") { put("items", JsonArray(listOf(item))) })
        val got = r.arr("items")!![0].jsonObject
        assertEquals("+14155552671", got["person"]!!.jsonObject["phone"]!!.jsonPrimitive.content)
        assertEquals("https://a.com", got["links"]!!.jsonArray[0].jsonPrimitive.content)
    }

    @Test fun openResult() {
        val ok = roundTrip(NotifOpen.result("k", true))
        assertEquals(true, ok.bool("ok")); assertNull(ok.str("error")); assertNull(ok.str("note"))
        val launched = roundTrip(NotifOpen.result("k", true, note = "launched app"))
        assertEquals("launched app", launched.str("note"))
        val bad = roundTrip(NotifOpen.result("k", false, error = "blocked"))
        assertEquals(false, bad.bool("ok")); assertEquals("blocked", bad.str("error")); assertEquals("k", bad.str("key"))
    }

    @Test fun openRequestParses() {
        val r = roundTrip(Message.of("notif.open") { put("key", "0|com.x|1|null|10") })
        assertEquals("0|com.x|1|null|10", r.str("key"))
    }

    @Test fun packageOfKey() {
        assertEquals("com.whatsapp", NotifOpen.packageOf("0|com.whatsapp|1|null|10123"))
        assertEquals("com.a_b.c1", NotifOpen.packageOf("0|com.a_b.c1|7|tag|10"))
        assertNull(NotifOpen.packageOf("sms-otp:123"))
        assertNull(NotifOpen.packageOf("0||1|null|10"))
        assertNull(NotifOpen.packageOf("0|com.x y|1|null|10"))
    }
}
