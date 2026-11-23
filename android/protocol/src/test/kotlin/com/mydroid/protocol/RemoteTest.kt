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
}
