package com.mydroid.protocol

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class RemoteTest {
    private fun roundTrip(m: Message): Message = Codec.decode(Codec.encode(m))

    @Test fun inputMessagesEncodeAndRoundTrip() {
        val move = roundTrip(RemoteWire.move(1.23456, -7.0))
        assertEquals("in.move", move.type)
        assertEquals(1.235, move.header["dx"]!!.jsonPrimitive.double, 1e-9)
        assertEquals(-7.0, move.header["dy"]!!.jsonPrimitive.double, 1e-9)

        val sc = roundTrip(RemoteWire.scroll(0.0, 12.5, "momentum"))
        assertEquals("momentum", sc.str("phase"))
        assertNull(roundTrip(RemoteWire.scroll(1.0, 2.0)).str("phase"))

        val click = roundTrip(RemoteWire.click("right", 2))
        assertEquals("right", click.str("button")); assertEquals(2, click.int("count"))
        assertEquals(2, RemoteWire.click("left", 9).int("count"))
        assertEquals(1, RemoteWire.click("left", 0).int("count"))
        assertEquals("in.down", RemoteWire.down("left").type); assertEquals("in.up", RemoteWire.up("left").type)

        assertEquals("hello", roundTrip(RemoteWire.text("hello")).str("text"))
        assertEquals("héllo 👍", roundTrip(RemoteWire.text("héllo 👍")).str("text"))
        assertEquals("playpause", roundTrip(RemoteWire.media("playpause")).str("action"))
        assertEquals("remote.ask", roundTrip(RemoteWire.remoteAsk()).type)
    }

    @Test fun keyModsAreOrderedAndOptional() {
        assertNull(RemoteWire.key("enter").arr("mods"))
        val k = roundTrip(RemoteWire.key("c", setOf("shift", "cmd", "ctrl")))
        assertEquals(listOf("cmd", "shift", "ctrl"), k.arr("mods")!!.map { it.jsonPrimitive.content })
    }

    @Test fun laserOnCarriesClampedPointOffDoesNot() {
        val on = roundTrip(RemoteWire.laser(true, 1.7, -0.2))
        assertTrue(on.bool("on")!!)
        assertEquals(1.0, on.header["x"]!!.jsonPrimitive.double, 0.0)
        assertEquals(0.0, on.header["y"]!!.jsonPrimitive.double, 0.0)
        val off = RemoteWire.laser(false)
        assertFalse(off.bool("on")!!); assertNull(off.header["x"])
    }

    @Test fun keyValidity() {
        assertTrue(RemoteKeys.valid("f12")); assertTrue(RemoteKeys.valid("a")); assertTrue(RemoteKeys.valid("👍"))
        assertFalse(RemoteKeys.valid("")); assertFalse(RemoteKeys.valid("ab")); assertFalse(RemoteKeys.valid("f13"))
    }

    @Test fun macActionsEncode() {
        val a = roundTrip(RemoteWire.macAction("r1", "shortcut", "Night mode"))
        assertEquals("mac.action", a.type); assertEquals("r1", a.str("req")); assertEquals("shortcut", a.str("action")); assertEquals("Night mode", a.str("name"))
        assertNull(RemoteWire.macAction("r2", "lock").str("name"))
        assertEquals("r3", RemoteWire.shortcutsGet("r3").str("req"))
    }

    @Test fun remoteStateParses() {
        val on = RemoteWire.parseRemoteState(Message.of("remote.state") { put("accessibility", true); put("presenting", buildJsonObject { put("app", "Keynote") }) })
        assertTrue(on.accessibility); assertEquals("Keynote", on.presenting!!.app)
        val off = RemoteWire.parseRemoteState(Message.of("remote.state") { put("accessibility", false); put("presenting", JsonNull) })
        assertFalse(off.accessibility); assertNull(off.presenting)
        assertFalse(RemoteWire.parseRemoteState(Message.of("remote.state")).accessibility)
        // presenting without an app name is still presenting
        assertEquals("", RemoteWire.parseRemoteState(Message.of("remote.state") { put("accessibility", true); put("presenting", buildJsonObject {}) }).presenting!!.app)
    }

    @Test fun macStatusParses() {
        val s = RemoteWire.parseMacStatus(Message.of("mac.status") {
            put("name", "Mac"); put("model", "MacBookAir"); put("battery", 82); put("charging", true); put("locked", true); put("displayAsleep", false)
        })
        assertEquals(82, s.battery); assertEquals("82% · Charging", s.batteryText); assertEquals(MacStatus.Presence.Locked, s.presence)
        val desktop = RemoteWire.parseMacStatus(Message.of("mac.status") { put("battery", JsonNull); put("displayAsleep", true); put("locked", true) })
        assertNull(desktop.battery); assertNull(desktop.batteryText); assertEquals(MacStatus.Presence.Asleep, desktop.presence)
        assertEquals(MacStatus.Presence.Awake, RemoteWire.parseMacStatus(Message.of("mac.status")).presence)
        assertEquals(100, RemoteWire.parseMacStatus(Message.of("mac.status") { put("battery", 140) }).battery)
    }

    @Test fun macResultAndShortcutsParse() {
        val r = RemoteWire.parseMacResult(Message.of("mac.result") { put("req", "r1"); put("ok", false); put("error", "no accessibility") })!!
        assertFalse(r.ok); assertEquals("no accessibility", r.error)
        assertNull(RemoteWire.parseMacResult(Message.of("mac.result") { put("ok", true) }))
        val l = RemoteWire.parseShortcuts(Message.of("mac.shortcuts") { put("req", "r2"); put("items", JsonArray(listOf(JsonPrimitive("A"), JsonPrimitive(""), JsonPrimitive("B"), JsonPrimitive(3)))) })!!
        assertEquals(listOf("A", "B"), l.items)
        val e = RemoteWire.parseShortcuts(Message.of("mac.shortcuts") { put("req", "r3"); put("error", "not installed") })!!
        assertNull(e.items); assertEquals("not installed", e.error)
    }

    @Test fun failureMessagesAreKind() {
        assertNull(MacMessages.failure("lock", null, true, null))
        assertTrue(MacMessages.failure("lock", null, false, "accessibility not granted")!!.contains("Accessibility"))
        assertEquals("Screen turned off, but may not be locked", MacMessages.failure("lock", null, true, null, "displaysleep"))
        assertEquals(MacMessages.DISPLAY_SLEEP_NOTE, MacMessages.failure("lock", null, true, "fallback"))
        assertNull(MacMessages.failure("sleep", null, true, null, "displaysleep"))
        val n = RemoteWire.parseMacResult(Message.of("mac.result") { put("req", "r9"); put("ok", true); put("note", "displaysleep") })!!
        assertTrue(n.ok); assertEquals("displaysleep", n.note); assertNull(n.error)
        assertTrue(MacMessages.failure("shortcut", "Night mode", false, "Shortcut not found")!!.contains("“Night mode”"))
        assertEquals("Couldn't ring your Mac. Try again in a moment.", MacMessages.failure("ring", null, false, "weird"))
        // never leaks the raw error text
        assertFalse(MacMessages.failure("sleep", null, false, "xpc error 0x5")!!.contains("xpc"))
    }

    @Test fun favoritesRoundTripAndToggle() {
        assertEquals(emptyList<String>(), Favorites.decode(null))
        val f = Favorites.toggle(Favorites.toggle(emptyList(), "A"), "B")
        assertEquals(listOf("A", "B"), Favorites.decode(Favorites.encode(f)))
        assertEquals(listOf("B"), Favorites.toggle(f, "A"))
        assertEquals(listOf("A"), Favorites.decode("A\n\n A \nA"))
    }

    // ---------------------------------------------------------------- RemoteInput

    private class Sent { val m = ArrayList<Message>(); val send: (Message) -> Unit = { m += it } }

    @Test fun cmdIsOneShotForKeysAndChars() {
        val s = Sent(); val i = RemoteInput(s.send)
        i.setCmd(true)
        i.ops(listOf(KeyOp.Text("Vx")))
        // first char becomes ⌘+v (lower case), the rest is plain text, and the toggle cleared itself
        assertEquals("in.key", s.m[0].type); assertEquals("v", s.m[0].str("key")); assertEquals(listOf("cmd"), s.m[0].arr("mods")!!.map { it.jsonPrimitive.content })
        assertEquals("in.text", s.m[1].type); assertEquals("x", s.m[1].str("text"))
        assertFalse(i.cmdArmed)
        i.setCmd(true); i.key("left")
        assertEquals(listOf("cmd"), s.m[2].arr("mods")!!.map { it.jsonPrimitive.content })
        assertFalse(i.cmdArmed)
        i.key("tab"); assertNull(s.m[3].arr("mods"))
    }

    @Test fun shortcutsLeaveTheToggleAlone() {
        val s = Sent(); val i = RemoteInput(s.send)
        i.setCmd(true)
        i.shortcut("up", setOf("ctrl"))
        assertTrue(i.cmdArmed)
        assertEquals(listOf("ctrl"), s.m[0].arr("mods")!!.map { it.jsonPrimitive.content })
    }

    @Test fun opsMapBackspaceEnterTab() {
        val s = Sent(); val i = RemoteInput(s.send)
        i.ops(listOf(KeyOp.Backspace, KeyOp.Text("hi"), KeyOp.Enter, KeyOp.Tab))
        assertEquals(listOf("backspace", null, "enter", "tab"), s.m.map { it.str("key") })
        assertEquals("hi", s.m[1].str("text"))
    }

    @Test fun invalidKeysAndMediaAreDropped() {
        val s = Sent(); val i = RemoteInput(s.send)
        i.key("nonsense"); i.media("explode"); i.media("mute")
        assertEquals(1, s.m.size); assertEquals("mute", s.m[0].str("action"))
    }

    @Test fun anyModifierCanBeArmedForTheNextKey() {
        val sent = ArrayList<Message>()
        val i = RemoteInput { sent += it }
        i.toggle("option"); i.toggle("ctrl")
        assertEquals(setOf("option", "ctrl"), i.armed)
        i.key("left")
        assertEquals(setOf<String>(), i.armed)
        val mods = (sent.single().header["mods"] as kotlinx.serialization.json.JsonArray).map { (it as kotlinx.serialization.json.JsonPrimitive).content }
        assertEquals(listOf("option", "ctrl"), mods)
    }

    @Test fun typedTextIsMirroredUntilEnter() {
        val i = RemoteInput { }
        val seen = ArrayList<String>()
        i.onTyped { seen += it }
        i.ops(listOf(KeyOp.Text("quarterly"), KeyOp.Text(" plan")))
        assertEquals("quarterly plan", i.typed)
        i.ops(listOf(KeyOp.Backspace))
        assertEquals("quarterly pla", i.typed)
        i.ops(listOf(KeyOp.Enter))
        assertEquals("", i.typed)
        assertEquals("", seen.last())
    }

    // ---------------------------------------------------------------- PROTOCOL.md 16

    @Test fun appsListParsesIconsAndSkipsDamagedEntries() {
        val png = java.util.Base64.getEncoder().encodeToString(byteArrayOf(1, 2, 3))
        val m = Message.of("mac.apps") {
            put("req", "r1")
            put("running", kotlinx.serialization.json.buildJsonArray {
                add(kotlinx.serialization.json.buildJsonObject { put("id", "com.apple.Safari"); put("name", "Safari"); put("icon", png) })
                add(kotlinx.serialization.json.buildJsonObject { put("name", "no id") })
            })
            put("apps", kotlinx.serialization.json.buildJsonArray { add(kotlinx.serialization.json.buildJsonObject { put("id", "com.apple.Notes"); put("name", "Notes") }) })
        }
        val l = RemoteWire.parseApps(m)!!
        assertEquals("r1", l.req)
        assertEquals(listOf("Safari"), l.running.map { it.name })
        assertArrayEquals(byteArrayOf(1, 2, 3), l.running.single().icon)
        assertEquals(listOf("Notes"), l.installed.map { it.name })
        assertNull(l.installed.single().icon)
        assertNull(RemoteWire.parseApps(Message.of("mac.apps")))
    }

    @Test fun presentStateParsesWhatTheAppCouldReport() {
        val full = RemoteWire.parsePresent(Message.of("present.state") { put("active", true); put("app", "Keynote"); put("index", 7); put("count", 24); put("notes", "Pause"); put("title", "Results") })
        assertEquals(PresentInfo(true, "Keynote", 7, 24, "Pause", "Results"), full)
        val partial = RemoteWire.parsePresent(Message.of("present.state") { put("active", true); put("app", "Keynote"); put("error", "automation") })
        assertEquals("automation", partial.error); assertNull(partial.index)
        assertFalse(RemoteWire.parsePresent(Message.of("present.state") { put("active", false) }).active)
        assertNull(RemoteWire.parsePresent(Message.of("present.state") { put("active", true); put("index", 0) }).index)
    }

    @Test fun macMediaExtrapolatesWhilePlayingAndStopsAtTheEnd() {
        val playing = MacMediaState(true, "Music", "t", "a", "b", playing = true, position = 10_000, duration = 200_000, ts = 1_000_000)
        assertEquals(15_000L, playing.positionAt(1_005_000))
        assertEquals(200_000L, playing.positionAt(9_000_000))
        assertEquals("a clock that is a little behind never goes backwards past the sample", 10_000L, playing.positionAt(900_000))
        val paused = MacMediaState(true, "Music", "t", "a", "b", playing = false, position = 10_000, duration = 200_000, ts = 1_000_000)
        assertEquals(10_000L, paused.positionAt(1_050_000))
    }

    @Test fun aNewerStateWithoutArtKeepsTheCoverOfTheSameTrackOnly() {
        val cover = byteArrayOf(9)
        val first = MacMediaState(true, "Music", "t", "a", "b", art = cover)
        val same = MacMediaState(true, "Music", "t", "a", "b", playing = true).withArtFrom(first)
        assertArrayEquals(cover, same.art)
        val other = MacMediaState(true, "Music", "t2", "a", "b").withArtFrom(first)
        assertNull(other.art)
        assertNull(MacMediaState(active = false).withArtFrom(first).art)
    }

    @Test fun macMediaParsesAndSurvivesBadBase64() {
        val art = java.util.Base64.getEncoder().encodeToString(byteArrayOf(5, 6))
        val m = RemoteWire.parseMacMedia(Message.of("mac.media") {
            put("active", true); put("app", "Spotify"); put("title", "T"); put("artist", "A"); put("album", "B"); put("playing", true)
            put("position", 1234L); put("duration", 200000L); put("ts", 1_795_000_000_000L); put("canSeek", true); put("art", art); put("volume", 0.4)
        })
        assertTrue(m.active); assertEquals("Spotify", m.app); assertEquals(1_795_000_000_000L, m.ts)
        assertArrayEquals(byteArrayOf(5, 6), m.art); assertEquals(0.4, m.volume!!, 1e-9)
        assertNull(RemoteWire.parseMacMedia(Message.of("mac.media") { put("active", true); put("art", "!!!") }).art)
        val idle = RemoteWire.parseMacMedia(Message.of("mac.media") { put("active", false); put("volume", 7.0); put("error", "automation") })
        assertFalse(idle.active); assertEquals(1.0, idle.volume!!, 1e-9); assertEquals("automation", idle.error)
    }

    @Test fun v2RequestsCarryTheirFields() {
        assertEquals("mac.launch", RemoteWire.launch("r", "com.apple.Notes").type)
        val p = RemoteWire.presentStart("r", "docs", "Work/Q3.key", true)
        assertEquals("Work/Q3.key", p.str("path")); assertEquals(true, p.bool("play"))
        assertEquals(61_500L, RemoteWire.mediaSeek(61_500).long("position"))
        assertEquals(0L, RemoteWire.mediaSeek(-5).long("position"))
        assertEquals("1.0", RemoteWire.mediaVolume(3.0).header["value"].toString())
        assertEquals(false, RemoteWire.presentWatch(false).bool("on"))
    }

    @Test fun decksAreRecognisedByExtension() {
        assertTrue(Decks.isDeck("Q3 Review.key")); assertTrue(Decks.isDeck("a.PPTX")); assertTrue(Decks.isDeck("x.pdf"))
        assertFalse(Decks.isDeck("notes.txt")); assertFalse(Decks.isDeck("keynote"))
        assertEquals("Keynote", Decks.kind("a.key")); assertEquals("Q3 Review", Decks.title("Q3 Review.key"))
    }
}
