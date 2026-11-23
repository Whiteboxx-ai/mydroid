package com.mydroid.protocol

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class PresenceTest {
    private val v = run {
        val f = listOf("../../protocol/test-vectors.json", "../protocol/test-vectors.json", "protocol/test-vectors.json").map { File(it) }.first { it.exists() }
        Json.parseToJsonElement(f.readText()).jsonObject
    }

    @Test fun bleUuidMatchesVector() {
        val ltk = Hex.decode(v["ltk"]!!.jsonPrimitive.content)
        assertEquals(v["bleUuid"]!!.jsonPrimitive.content, Ble.serviceUuid(ltk))
    }

    @Test fun phoneBleUuidMatchesVector() {
        val ltk = Hex.decode(v["ltk"]!!.jsonPrimitive.content)
        val u = Ble.phoneServiceUuid(ltk)
        assertEquals(v["phoneBleUuid"]!!.jsonPrimitive.content, u)
        // The vector's raw form is HKDF output before the RFC 4122 version and variant bits.
        val raw = Hkdf.derive(ltk, ByteArray(0), "mydroid v1 phone ble uuid", 16)
        assertEquals(v["phoneBleUuidRaw"]!!.jsonPrimitive.content, Hex.encode(raw))
        assertNotEquals(Ble.serviceUuid(ltk), u)
    }

    @Test fun disabledNeverParks() {
        val m = PresenceMachine(120_000)
        assertFalse(m.parked(10_000_000))
        assertNull(m.msUntilPark(0))
    }

    @Test fun parksAfterTwoMinutesOfNoMacAndNoTcp() {
        val m = PresenceMachine(120_000)
        m.setEnabled(true, 0)
        assertFalse(m.parked(119_999))
        assertEquals(120_000L, m.msUntilPark(0))
        assertTrue(m.parked(120_000))
    }

    @Test fun presenceOrTcpKeepsItRunningAndLossRestartsWindow() {
        val m = PresenceMachine(120_000)
        m.setEnabled(true, 0)
        m.onFound()
        assertFalse(m.parked(1_000_000)); assertNull(m.msUntilPark(1_000_000))
        m.onLost(1_000_000)
        assertFalse(m.parked(1_119_999)); assertTrue(m.parked(1_120_000))
        m.onTcp(true, 1_200_000)
        assertFalse(m.parked(9_000_000))
        m.onTcp(false, 2_000_000)
        assertFalse(m.parked(2_100_000)); assertTrue(m.parked(2_120_000))
    }

    @Test fun lostWhileConnectedDoesNotParkUntilTcpEnds() {
        val m = PresenceMachine(120_000)
        m.setEnabled(true, 0); m.onFound(); m.onTcp(true, 10)
        m.onLost(1_000)
        assertFalse(m.parked(500_000))
        m.onTcp(false, 500_000)
        assertFalse(m.parked(600_000)); assertTrue(m.parked(620_000))
    }

    @Test fun wakeUnparksForAnotherWindowAndFoundUnparks() {
        val m = PresenceMachine(120_000)
        m.setEnabled(true, 0)
        assertTrue(m.parked(200_000))
        m.wake(200_000)
        assertFalse(m.parked(300_000)); assertTrue(m.parked(320_000))
        m.onFound(); assertFalse(m.parked(900_000))
    }

    @Test fun linksOnlyHttpHttpsMailto() {
        assertEquals("https://example.com/a?b=1", Links.safe(" https://example.com/a?b=1 "))
        assertEquals("HTTP://x.org", Links.safe("HTTP://x.org"))
        assertEquals("mailto:a@b.co", Links.safe("mailto:a@b.co"))
        for (bad in listOf("javascript:alert(1)", "intent://x#Intent;end", "file:///etc/passwd", "tel:123", "content://x", "https:example.com", "https:///x", "http://a b", "", "example.com", "mailto:")) {
            assertNull(bad, Links.safe(bad))
        }
        assertNull(Links.safe(null))
    }

    @Test fun mutingWithdrawsAlreadyMirroredOnly() {
        val t = MuteTracker()
        t.sent("k1", "com.android.shell"); t.sent("k2", "com.other")
        assertFalse(t.isMuted("com.android.shell"))
        assertEquals(listOf("k1"), t.update(setOf("com.android.shell")))
        assertTrue(t.isMuted("com.android.shell"))
        assertEquals(emptyList<String>(), t.update(setOf("com.android.shell")))
        t.sent("k3", "com.x"); t.forget("k3")
        assertEquals(emptyList<String>(), t.update(setOf("com.x")))
    }

    private fun snap(pos: Long, ts: Long, playing: Boolean = true, title: String = "t", art: Boolean = false, next: Boolean = true) =
        MediaSnapshot("p", title, "a", "al", playing, pos, 200_000, ts, true, next, true, art)

    @Test fun mediaSendsOnChangeOnly() {
        val t = MediaTracker()
        assertFalse(t.decide(null).send)
        assertTrue(t.decide(snap(0, 0, art = true)).send)
        // periodic position refresh on the extrapolated line: nothing
        assertFalse(t.decide(snap(5_000, 5_000, art = true)).send)
        assertFalse(t.decide(snap(30_000, 30_000, art = true)).send)
        // seek
        assertTrue(t.decide(snap(120_000, 31_000, art = true)).send)
        // pause
        val pause = t.decide(snap(121_000, 32_000, playing = false, art = true))
        assertTrue(pause.send); assertFalse(pause.withArt)
        // paused, same position: nothing
        assertFalse(t.decide(snap(121_000, 90_000, playing = false, art = true)).send)
        // can-next changes
        assertTrue(t.decide(snap(121_000, 91_000, playing = false, art = true, next = false)).send)
    }

    @Test fun mediaArtOnlyOncePerTrack() {
        val t = MediaTracker()
        val first = t.decide(snap(0, 0, art = true)); assertTrue(first.send); assertTrue(first.withArt)
        val pl = t.decide(snap(1_000, 1_000, playing = false, art = true)); assertTrue(pl.send); assertFalse(pl.withArt)
        val next = t.decide(snap(0, 2_000, title = "u", art = true)); assertTrue(next.send); assertTrue(next.withArt)
        // art arrives late for a track
        val t2 = MediaTracker()
        assertFalse(t2.decide(snap(0, 0, art = false)).withArt)
        val late = t2.decide(snap(10, 10, art = true)); assertTrue(late.send); assertTrue(late.withArt)
    }

    @Test fun mediaInactiveSentOnceThenSilent() {
        val t = MediaTracker()
        t.decide(snap(0, 0))
        assertTrue(t.decide(null).send)
        assertFalse(t.decide(null).send)
        assertTrue(t.decide(snap(0, 5)).send)
    }

    // ---- mediaId in media.state (PROTOCOL.md 15)

    private val track = "spotify:track:6rqhFgbbKwnb9MLmUQDhG6"
    private val episode = "spotify:episode:512ojhOuo1ktJprKbVcKyQ"
    private fun withId(id: String?, pos: Long = 0, ts: Long = 0, playing: Boolean = true, title: String = "t") =
        MediaSnapshot("com.spotify.music", title, "a", "al", playing, pos, 200_000, ts, true, true, true, false, mediaId = id)

    @Test fun mediaStateCarriesAFilteredId() {
        val m = withId(track).toMessage("Spotify", null)
        assertEquals("media.state", m.type); assertEquals(track, m.str("mediaId")); assertEquals(true, m.bool("active"))
        assertEquals(episode, withId(episode).toMessage("Spotify", null).str("mediaId"))
        assertEquals("https://open.spotify.com/track/abc", withId("https://open.spotify.com/track/abc").toMessage("Spotify", null).str("mediaId"))
    }

    @Test fun mediaStateOmitsIdsThatDontQualify() {
        for (bad in listOf(null, "", "spotify:track:abc", "spotify:track:6rqhFgbbKwnb9MLmUQDhG6X", "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M", "content://media/42", "1234567", "spotify:track:6rqhFgbbKwnb9MLmUQDh-6"))
            assertFalse("sent $bad", withId(bad).toMessage("Spotify", null).header.containsKey("mediaId"))
    }

    @Test fun mediaStateStillHasEverythingElse() {
        val m = withId(track, pos = 5_000, ts = 99).toMessage("Spotify", "QUJD")
        assertEquals("Spotify", m.str("app")); assertEquals("QUJD", m.str("art")); assertEquals(5_000L, m.long("position")); assertEquals(99L, m.long("ts"))
        assertEquals(true, m.bool("canNext")); assertFalse(withId(null).toMessage("Spotify", null).header.containsKey("art"))
    }

    @Test fun mediaIdFollowsTheTrack() {
        val t = MediaTracker()
        assertTrue(t.decide(withId(track)).send)
        // Same track, only the position moved along the line: nothing to send.
        assertFalse(t.decide(withId(track, pos = 5_000, ts = 5_000)).send)
        // Next track on the same title (a repeat of an episode series): the id changed, so it is a new track.
        assertTrue(t.decide(withId(episode, pos = 6_000, ts = 6_000)).send)
        // The id appears late for the same track: that is worth telling the Mac.
        val t2 = MediaTracker()
        assertTrue(t2.decide(withId(null)).send)
        assertTrue(t2.decide(withId(track, pos = 100, ts = 100)).send)
    }

    @Test fun mediaCommands() {
        assertEquals(MediaAction.Pause, MediaAction.parse("pause", playing = true))
        assertEquals(MediaAction.Pause, MediaAction.parse("pause", playing = false))
        assertEquals(MediaAction.Play, MediaAction.parse("play", playing = true))
        assertEquals(MediaAction.Pause, MediaAction.parse("toggle", playing = true))
        assertEquals(MediaAction.Play, MediaAction.parse("toggle", playing = false))
        assertEquals(MediaAction.Next, MediaAction.parse("next", true)); assertEquals(MediaAction.Prev, MediaAction.parse("prev", true)); assertEquals(MediaAction.Seek, MediaAction.parse("seek", true))
        assertNull(MediaAction.parse("stop", true)); assertNull(MediaAction.parse("", true)); assertNull(MediaAction.parse(null, true))
    }
}
