package com.mydroid.protocol

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

private fun roundTrip(m: Message): Message = Codec.decode(Codec.encode(m))

class PagingTest {
    private data class Row(val id: Int, val date: Long)
    private val date = { r: Row -> r.date }

    @Test fun takesLimitAndReportsMore() {
        val rows = (10 downTo 1).map { Row(it, it * 1000L) }
        val p = Paging.page(rows, 4, date)
        assertEquals(listOf(10, 9, 8, 7), p.items.map { it.id })
        assertTrue(p.more)
        val all = Paging.page(rows, 10, date)
        assertEquals(10, all.items.size); assertFalse(all.more)
        assertTrue(Paging.page(rows, 10, date, moreBeyondInput = true).more)
    }

    @Test fun neverSplitsAGroupOfEqualDates() {
        // Three screenshots in the same second at the edge: the next page (date < edge) must not lose them.
        val rows = listOf(Row(1, 9000), Row(2, 8000), Row(3, 7000), Row(4, 7000), Row(5, 7000), Row(6, 6000))
        val p = Paging.page(rows, 3, date)
        assertEquals(listOf(1, 2, 3, 4, 5), p.items.map { it.id })
        assertTrue(p.more)
        // Paging the rest by `date < 7000` finds exactly the remainder.
        val rest = rows.filter { it.date < 7000 }
        assertEquals(listOf(6), Paging.page(rest, 3, date).items.map { it.id })
    }

    @Test fun mergeKeepsNewestFirstAndIsStable() {
        val a = listOf(Row(1, 50), Row(2, 30), Row(3, 10))
        val b = listOf(Row(4, 40), Row(5, 30), Row(6, 5))
        assertEquals(listOf(1, 4, 2, 5, 3, 6), Paging.merge(a, b, date).map { it.id })
        assertEquals(listOf(1, 2), Paging.merge(listOf(Row(1, 1)), listOf(Row(2, 1)), date).map { it.id })
        assertEquals(emptyList<Row>(), Paging.merge(emptyList(), emptyList(), date))
    }

    @Test fun limitIsClamped() {
        assertEquals(50, Paging.limit(null, 50, 200))
        assertEquals(1, Paging.limit(0, 50, 200))
        assertEquals(200, Paging.limit(10_000, 50, 200))
        assertEquals(7, SmsWire.limit(7))
        assertEquals(60, PhotoWire.limit(null))
        assertEquals(100, CallWire.limit(null))
    }

    @Test fun idsAcceptNumbersAndStrings() {
        val m = Message.of("photos.thumbs.get") {
            put("id", "42"); put("threadId", 7L)
            put("ids", buildJsonArray { add(1); add("2"); add("x"); add(3L) })
        }
        assertEquals(42L, m.flexLong("id")); assertEquals(7L, m.flexLong("threadId")); assertNull(m.flexLong("nope"))
        assertEquals(listOf(1L, 2L, 3L), m.flexLongs("ids"))
    }
}

class SmsWireTest {
    private fun thread(i: Int, avatar: String? = null) = SmsThread(i.toLong(), listOf("+1555000$i"), "Name $i", "snippet $i", 1_700_000_000_000L - i, i % 3, avatar)

    @Test fun threadsRoundTrip() {
        val d = roundTrip(SmsWire.threads(listOf(thread(1, "QUJD"), thread(2))))
        assertEquals("sms.threads", d.type)
        val ts = d.arr("threads")!!
        assertEquals(2, ts.size)
        val t0 = ts[0].jsonObject
        assertEquals(1L, t0["threadId"]!!.jsonPrimitive.long)
        assertEquals("+15550001", t0["addresses"]!!.jsonArray[0].jsonPrimitive.content)
        assertEquals("QUJD", t0["avatar"]!!.jsonPrimitive.content)
        assertEquals(1, t0["unread"]!!.jsonPrimitive.int)
        assertNull(ts[1].jsonObject["avatar"])
    }

    @Test fun hugeAvatarsAreShedBeforeThreadsAreDropped() {
        val avatar = "A".repeat(40_000) // 50 threads x 40 KB = 2 MB
        val threads = (1..50).map { thread(it, avatar) }
        val m = SmsWire.threads(threads)
        assertTrue("frame ${Codec.encode(m).size}", FrameBudget.fits(m))
        val out = m.arr("threads")!!
        assertEquals("all threads kept, only avatars shed", 50, out.size)
        // The newest threads keep their avatars, the oldest lose them.
        assertNotNull(out[0].jsonObject["avatar"])
        assertNull(out[49].jsonObject["avatar"])
        assertTrue(out.count { it.jsonObject["avatar"] != null } in 1..49)
    }

    @Test fun threadsAreTruncatedWhenEvenTextAloneIsTooBig() {
        val long = "x".repeat(SmsWire.MAX_SNIPPET)
        val threads = (1..200).map { thread(it).copy(addresses = List(400) { a -> "+1555000000$a$it" }, snippet = long) }
        val m = SmsWire.threads(threads)
        assertTrue(FrameBudget.fits(m))
        assertTrue(m.arr("threads")!!.size in 1 until 200)
        assertEquals(1L, m.arr("threads")!![0].jsonObject["threadId"]!!.jsonPrimitive.long)
    }

    @Test fun snippetsAndBodiesAreClippedWithoutBreakingEmoji() {
        val s = "a".repeat(SmsWire.MAX_SNIPPET - 1) + "😀😀"
        val c = SmsWire.clip(s, SmsWire.MAX_SNIPPET)
        assertEquals(SmsWire.MAX_SNIPPET - 1, c.length)
        assertEquals("abc", SmsWire.clip("abc", 10))
        val d = roundTrip(SmsWire.messages(1, listOf(SmsMsg(1, "x", "b".repeat(20_000), 5, false, "received"))))
        assertEquals(SmsWire.MAX_BODY, d.arr("messages")!![0].jsonObject["body"]!!.jsonPrimitive.content.length)
    }

    @Test fun messagesRoundTripOldestFirstWithMmsFlag() {
        val d = roundTrip(SmsWire.messages(9, listOf(
            SmsMsg(1, "+1555", "hi", 1000, false, "received"),
            SmsMsg(-4, "", "[Photo]", 2000, true, "sent", mms = true),
        )))
        assertEquals(9L, d.long("threadId"))
        val ms = d.arr("messages")!!
        assertEquals(1000L, ms[0].jsonObject["date"]!!.jsonPrimitive.long)
        assertNull(ms[0].jsonObject["mms"])
        assertEquals(true, ms[1].jsonObject["mms"]!!.jsonPrimitive.boolean)
        assertEquals(-4L, ms[1].jsonObject["id"]!!.jsonPrimitive.long)
        assertEquals(true, ms[1].jsonObject["out"]!!.jsonPrimitive.boolean)
        assertEquals("", ms[1].jsonObject["from"]!!.jsonPrimitive.content)
    }

    @Test fun tooManyBigMessagesKeepTheNewest() {
        val msgs = (1..200).map { SmsMsg(it.toLong(), "+1", "m".repeat(7_000), it * 1000L, false, "received") }
        val m = SmsWire.messages(1, msgs)
        assertTrue(FrameBudget.fits(m))
        val out = m.arr("messages")!!
        assertTrue(out.size in 1 until 200)
        assertEquals(200L, out.last().jsonObject["id"]!!.jsonPrimitive.long)
        // Still oldest first, and contiguous up to the newest.
        val ids = out.map { it.jsonObject["id"]!!.jsonPrimitive.long }
        assertEquals(ids.sorted(), ids)
        assertEquals(ids.last() - ids.first() + 1, ids.size.toLong())
    }

    @Test fun statusAndDirectionMapping() {
        assertEquals("received", SmsWire.statusOfSmsType(1)); assertEquals("sent", SmsWire.statusOfSmsType(2))
        assertEquals("pending", SmsWire.statusOfSmsType(4)); assertEquals("pending", SmsWire.statusOfSmsType(6))
        assertEquals("failed", SmsWire.statusOfSmsType(5))
        assertEquals("received", SmsWire.statusOfMmsBox(1)); assertEquals("sent", SmsWire.statusOfMmsBox(2)); assertEquals("pending", SmsWire.statusOfMmsBox(4))
        assertFalse(SmsWire.isOutSmsType(1)); assertTrue(SmsWire.isOutSmsType(2)); assertTrue(SmsWire.isOutSmsType(5))
        assertFalse(SmsWire.isOutMmsBox(1)); assertTrue(SmsWire.isOutMmsBox(2))
    }

    @Test fun mmsBodyIsTextOrPlaceholder() {
        assertEquals("see you", SmsWire.mmsBody(listOf(" see you "), listOf("image/jpeg", "text/plain")))
        assertEquals("[Photo]", SmsWire.mmsBody(emptyList(), listOf("application/smil", "image/jpeg")))
        assertEquals("[Photo]", SmsWire.mmsBody(listOf("  "), listOf("image/png")))
        assertEquals("[Video]", SmsWire.mmsBody(emptyList(), listOf("video/3gpp")))
        assertEquals("[Attachment]", SmsWire.mmsBody(emptyList(), listOf("application/smil")))
        assertEquals("[Photo]", SmsWire.snippet(null, true)); assertEquals("", SmsWire.snippet("  ", false)); assertEquals("hey", SmsWire.snippet(" hey ", true))
    }

    @Test fun errorsAndSentShapes() {
        val e = roundTrip(SmsWire.error("permission", "sms.threads.get"))
        assertEquals("sms.error", e.type); assertEquals("permission", e.str("error"))
        val ok = roundTrip(SmsWire.sent("c1", true, null, 12))
        assertEquals("c1", ok.str("clientId")); assertEquals(true, ok.bool("ok")); assertNull(ok.str("error")); assertEquals(12L, ok.long("threadId"))
        val bad = roundTrip(SmsWire.sent("c2", false, "no signal", null))
        assertEquals(false, bad.bool("ok")); assertEquals("no signal", bad.str("error")); assertNull(bad.long("threadId"))
        assertEquals(5L, roundTrip(SmsWire.changed(5)).long("threadId"))
    }

    @Test fun phoneKeysAndNames() {
        assertEquals("5551234567", PhoneKey.of("+1 (555) 123-4567").takeLast(10))
        assertEquals(PhoneKey.of("+91 98765 43210"), PhoneKey.of("098765 43210"))
        assertEquals("vm-hdfcbk", PhoneKey.of("VM-HDFCBK"))
        assertEquals("A, B", ThreadNames.title(listOf("A", "B")))
        assertEquals("A, B, C +2", ThreadNames.title(listOf("A", "B", "C", "D", "E")))
        assertEquals("", ThreadNames.title(emptyList()))
    }
}

class SendTrackerTest {
    @Test fun multipartReportsOnceWhenTheLastPartIsIn() {
        val t = SendTracker()
        t.begin("c1", 3, 7)
        assertNull(t.partResult("c1", true, null))
        assertNull(t.partResult("c1", true, null))
        val o = t.partResult("c1", true, null)!!
        assertTrue(o.ok); assertEquals(7L, o.threadId); assertNull(o.error)
        assertNull("late duplicate is ignored", t.partResult("c1", true, null))
        assertFalse(t.isPending("c1"))
    }

    @Test fun firstErrorWinsAndStillWaitsForAllParts() {
        val t = SendTracker()
        t.begin("c2", 2, null)
        assertNull(t.partResult("c2", false, "no signal"))
        val o = t.partResult("c2", false, "other")!!
        assertFalse(o.ok); assertEquals("no signal", o.error); assertNull(o.threadId)
    }

    @Test fun recipientsTimesPartsAndExpiry() {
        val t = SendTracker()
        t.begin("c3", 2 * 3, 1)
        repeat(5) { assertNull(t.partResult("c3", true, null)) }
        val o = t.expire("c3")!!
        assertFalse(o.ok); assertNotNull(o.error)
        assertNull(t.expire("c3")); assertNull(t.partResult("c3", true, null)); assertNull(t.partResult("nope", true, null))
    }

    @Test fun errorCodesAreWords() {
        assertTrue(SmsErrors.describe(2).contains("airplane")); assertTrue(SmsErrors.describe(4).contains("service"))
        assertFalse(SmsErrors.describe(1).isBlank()); assertFalse(SmsErrors.describe(99).isBlank())
    }
}

class ThreadChangeTrackerTest {
    private fun sig(date: Long, n: Int = 1, read: Int = 1) = ThreadChangeTracker.Sig(date, n, read)

    @Test fun firstSnapshotIsOnlyABaseline() {
        val t = ThreadChangeTracker()
        val r = t.diff(mapOf(1L to sig(10), 2L to sig(20)), 0)
        assertTrue(r.changed.isEmpty()); assertNull(r.retryInMs)
        assertTrue(t.diff(mapOf(1L to sig(10), 2L to sig(20)), 5000).changed.isEmpty())
    }

    @Test fun announcesNewChangedReadAndDeletedThreads() {
        val t = ThreadChangeTracker()
        t.diff(mapOf(1L to sig(10), 2L to sig(20)), 0)
        val r = t.diff(mapOf(1L to sig(11, 2), 2L to sig(20, read = 0), 3L to sig(30)), 10_000)
        assertEquals(setOf(1L, 2L, 3L), r.changed.toSet())
        val gone = t.diff(mapOf(1L to sig(11, 2), 2L to sig(20, read = 0)), 20_000)
        assertEquals(listOf(3L), gone.changed)
    }

    @Test fun atMostOnePerSecondPerThreadAndNothingIsLost() {
        val t = ThreadChangeTracker(1000)
        t.diff(mapOf(1L to sig(10)), 0)
        assertEquals(listOf(1L), t.diff(mapOf(1L to sig(11)), 5_000).changed)
        // Another change 300 ms later is held back, with a retry hint for the remaining 700 ms.
        val held = t.diff(mapOf(1L to sig(12)), 5_300)
        assertTrue(held.changed.isEmpty()); assertEquals(700L, held.retryInMs)
        // A different thread isn't held back by thread 1.
        assertEquals(listOf(2L), t.diff(mapOf(1L to sig(12), 2L to sig(1)), 5_400).changed)
        // After the interval the held change goes out, exactly once.
        assertEquals(listOf(1L), t.diff(mapOf(1L to sig(12), 2L to sig(1)), 6_100).changed)
        assertTrue(t.diff(mapOf(1L to sig(12), 2L to sig(1)), 7_500).changed.isEmpty())
    }

    @Test fun resetStartsOver() {
        val t = ThreadChangeTracker()
        t.diff(mapOf(1L to sig(10)), 0)
        t.reset()
        assertTrue(t.diff(mapOf(1L to sig(99)), 10).changed.isEmpty())
    }
}

class PhotoWireTest {
    private fun item(id: Long, taken: Long) = PhotoItem(id, "IMG_$id.jpg", taken, 4000, 3000, 2_500_000, "image/jpeg", "camera")

    @Test fun pageRoundTrip() {
        val d = roundTrip(PhotoWire.page(Page(listOf(item(5, 1_700_000_000_000), item(4, 1_699_999_000_000)), true)))
        assertEquals("photos.page", d.type); assertEquals(true, d.bool("more"))
        val it0 = d.arr("items")!![0].jsonObject
        assertEquals(5L, it0["id"]!!.jsonPrimitive.long); assertEquals("IMG_5.jpg", it0["name"]!!.jsonPrimitive.content)
        assertEquals(4000, it0["w"]!!.jsonPrimitive.int); assertEquals("image/jpeg", it0["mime"]!!.jsonPrimitive.content)
        assertEquals("camera", it0["album"]!!.jsonPrimitive.content)
        assertNull(d.str("error"))
        assertEquals("permission", roundTrip(PhotoWire.page(Page(emptyList(), false), "permission")).str("error"))
    }

    @Test fun twoSourcesMergeByEffectiveDateWithFallbackToDateAdded() {
        assertEquals(1_700_000_000_000, PhotoWire.effectiveDate(1_700_000_000_000, 5))
        assertEquals(5_000, PhotoWire.effectiveDate(0, 5)); assertEquals(5_000, PhotoWire.effectiveDate(null, 5))
        val taken = listOf(item(1, 9_000), item(2, 3_000))
        val added = listOf(item(3, 5_000), item(4, 1_000)) // DATE_TAKEN missing, DATE_ADDED 5 s and 1 s
        val merged = Paging.merge(taken, added) { it.taken }
        assertEquals(listOf(1L, 3L, 2L, 4L), merged.map { it.id })
        assertEquals(listOf(1L, 3L, 2L), Paging.page(merged, 3, { it.taken }).items.map { it.id })
    }

    @Test fun albumsAndSizes() {
        assertEquals("all", PhotoWire.album(null)); assertEquals("all", PhotoWire.album("nope")); assertEquals("camera", PhotoWire.album("Camera")); assertEquals("screenshots", PhotoWire.album("screenshots"))
        assertEquals("camera", PhotoWire.albumOf("DCIM/Camera/", "IMG_1.jpg"))
        assertEquals("screenshots", PhotoWire.albumOf("Pictures/Screenshots/", "x.png"))
        assertEquals("screenshots", PhotoWire.albumOf("DCIM/Screenshots/", "x.png"))
        assertEquals("screenshots", PhotoWire.albumOf("Pictures/", "Screenshot_2026.png"))
        assertEquals("other", PhotoWire.albumOf("Pictures/WhatsApp/", "IMG-1.jpg")); assertEquals("other", PhotoWire.albumOf(null, null))
        assertEquals(3000 to 4000, PhotoWire.displaySize(4000, 3000, 90)); assertEquals(4000 to 3000, PhotoWire.displaySize(4000, 3000, 0))
        assertEquals(256 to 192, PhotoWire.fitSize(4000, 3000)); assertEquals(192 to 256, PhotoWire.fitSize(3000, 4000))
        assertEquals(100 to 50, PhotoWire.fitSize(100, 50)); assertEquals(256 to 1, PhotoWire.fitSize(5000, 1))
        assertEquals("lib:42", PhotoWire.libraryXid(42))
    }

    @Test fun thumbCarriesJpegPayloadOrAFailureFlag() {
        val jpeg = ByteArray(5_000) { (it % 251).toByte() }
        val d = roundTrip(PhotoWire.thumb(7, jpeg))
        assertEquals("photos.thumb", d.type); assertEquals(7L, d.long("id")); assertArrayEquals(jpeg, d.payload); assertNull(d.bool("ok"))
        val f = roundTrip(PhotoWire.thumb(8, null))
        assertEquals(8L, f.long("id")); assertEquals(false, f.bool("ok")); assertEquals(0, f.payload.size)
        assertTrue(FrameBudget.fits(PhotoWire.thumb(9, ByteArray(300_000))))
    }
}

class CallWireTest {
    @Test fun kindMapping() {
        assertEquals("in", CallWire.kindOf(1)); assertEquals("out", CallWire.kindOf(2)); assertEquals("missed", CallWire.kindOf(3))
        assertEquals("in", CallWire.kindOf(4)); assertEquals("rejected", CallWire.kindOf(5)); assertEquals("rejected", CallWire.kindOf(6)); assertEquals("in", CallWire.kindOf(7))
    }

    @Test fun pageRoundTrip() {
        val d = roundTrip(CallWire.page(listOf(CallItem("+15551234", "Maya", "missed", 1_700_000_000_000, 0), CallItem("+15559999", "+15559999", "out", 1_699_000_000_000, 61))))
        assertEquals("calls.page", d.type)
        val a = d.arr("items")!!
        assertEquals("missed", a[0].jsonObject["kind"]!!.jsonPrimitive.content); assertEquals(61L, a[1].jsonObject["duration"]!!.jsonPrimitive.long)
        assertEquals("Maya", a[0].jsonObject["name"]!!.jsonPrimitive.content)
        assertEquals("permission", roundTrip(CallWire.page(emptyList(), "permission")).str("error"))
    }

    @Test fun dialableNumbers() {
        assertEquals("+15551234567", CallWire.dialable(" +1 (555) 123-4567 "))
        assertEquals("09876543210", CallWire.dialable("098765 43210"))
        assertEquals("112", CallWire.dialable("112"))
        for (bad in listOf(null, "", "  ", "12", "*#06#", "*21*123#", "555;1234", "tel:555123", "+1+555123", "55+5123", "abc", "1".repeat(21), "1234 5678 9012 3456 7890 12345 6789")) assertNull("$bad", CallWire.dialable(bad))
    }
}

class MarkReadTest {
    @Test fun semanticActionWins() {
        assertTrue(MarkRead.isMarkRead(MarkRead.SEMANTIC_MARK_AS_READ, "Whatever"))
        assertTrue(MarkRead.isMarkRead(MarkRead.SEMANTIC_MARK_AS_READ, null))
        assertFalse(MarkRead.isMarkRead(0, "Reply")); assertFalse(MarkRead.isMarkRead(1, "Reply"))
    }

    @Test fun titlesCaseInsensitiveAndLocalised() {
        for (t in listOf("Mark as read", "mark as read", " MARK AS READ ", "Mark as read.", "Marcar como leído", "Marquer comme lu", "Als gelesen markieren", "标记为已读", "既読にする", "Mark all as read")) assertTrue(t, MarkRead.titleMatches(t))
        for (t in listOf("Mark as unread", "Reply", "Mute", "Mark as spam", "Read more", "", "Open")) assertFalse(t, MarkRead.titleMatches(t))
        assertFalse(MarkRead.titleMatches(null))
    }
}
