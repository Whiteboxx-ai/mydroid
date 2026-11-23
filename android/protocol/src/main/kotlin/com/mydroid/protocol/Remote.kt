package com.mydroid.protocol

import kotlinx.serialization.json.*

/**
 * PROTOCOL.md 10 (Remote), 11 (Quick actions, Mac status). Pure JVM: wire builders and parsers, plus the small pieces of
 * logic that decide what is sent (modifier handling, the favourites list, kind error text). Nothing here touches Android.
 */

object RemoteKeys {
    val NAMED: Set<String> = buildSet {
        addAll(listOf("left", "right", "up", "down", "enter", "escape", "space", "tab", "backspace", "delete", "home", "end", "pageup", "pagedown"))
        for (i in 1..12) add("f$i")
    }
    /** `mods` in the order they are written on the wire. */
    val MODS = listOf("cmd", "shift", "option", "ctrl")
    val MEDIA = setOf("playpause", "next", "prev", "volup", "voldown", "mute")

    /** A named key, or one single character (one Unicode code point). */
    fun valid(key: String): Boolean = key in NAMED || (key.isNotEmpty() && key.codePointCount(0, key.length) == 1)
}

/** `remote.state`: what the Mac can do right now, and whether it looks like a presentation is running (PROTOCOL.md 10). */
data class RemoteState(val accessibility: Boolean, val presenting: Presenting?)
data class Presenting(val app: String)

/** `mac.status` (PROTOCOL.md 11). */
data class MacStatus(
    val name: String, val model: String, val battery: Int?, val charging: Boolean, val locked: Boolean, val displayAsleep: Boolean,
) {
    enum class Presence { Awake, Locked, Asleep }
    val presence: Presence get() = when {
        displayAsleep -> Presence.Asleep
        locked -> Presence.Locked
        else -> Presence.Awake
    }

    /** "82%" or "82% · Charging"; null on a desktop Mac with no battery. */
    val batteryText: String? get() = battery?.let { "$it%" + if (charging) " · Charging" else "" }
}

/** [note] is additive info on a success: `"displaysleep"` means the lock fell back to turning the display off. */
data class MacResult(val req: String, val ok: Boolean, val error: String?, val note: String? = null)

/** `mac.shortcuts`: [items] is null when the Mac answered with an [error]. */
data class ShortcutList(val req: String, val items: List<String>?, val error: String?)

object RemoteWire {
    fun move(dx: Double, dy: Double) = Message.of("in.move") { put("dx", r3(dx)); put("dy", r3(dy)) }

    fun scroll(dx: Double, dy: Double, phase: String? = null) = Message.of("in.scroll") {
        put("dx", r3(dx)); put("dy", r3(dy)); if (phase != null) put("phase", phase)
    }

    fun click(button: String = "left", count: Int = 1) = Message.of("in.click") { put("button", button); put("count", count.coerceIn(1, 2)) }
    fun down(button: String = "left") = Message.of("in.down") { put("button", button) }
    fun up(button: String = "left") = Message.of("in.up") { put("button", button) }

    fun key(key: String, mods: Set<String> = emptySet()) = Message.of("in.key") {
        put("key", key)
        val m = RemoteKeys.MODS.filter { it in mods }
        if (m.isNotEmpty()) put("mods", JsonArray(m.map { JsonPrimitive(it) }))
    }

    fun text(text: String) = Message.of("in.text") { put("text", text) }
    fun media(action: String) = Message.of("in.media") { put("action", action) }

    /** [x] and [y] are 0..1 over the Mac's main display; they are only sent while [on]. */
    fun laser(on: Boolean, x: Double = 0.5, y: Double = 0.5) = Message.of("in.laser") {
        put("on", on)
        if (on) { put("x", r4(x.coerceIn(0.0, 1.0))); put("y", r4(y.coerceIn(0.0, 1.0))) }
    }

    fun remoteAsk() = Message.of("remote.ask")

    fun macAction(req: String, action: String, name: String? = null) = Message.of("mac.action") {
        put("req", req); put("action", action); if (name != null) put("name", name)
    }
    fun shortcutsGet(req: String) = Message.of("mac.shortcuts.get") { put("req", req) }

    private fun r3(v: Double) = Math.round(v * 1000.0) / 1000.0
    private fun r4(v: Double) = Math.round(v * 10000.0) / 10000.0

    // ---------------------------------------------------------------- parsing (M->P)

    fun parseRemoteState(m: Message): RemoteState {
        val p = m.header["presenting"] as? JsonObject
        return RemoteState(
            accessibility = m.bool("accessibility") == true,
            presenting = p?.let { Presenting((it["app"] as? JsonPrimitive)?.contentOrNull?.takeIf { a -> a.isNotBlank() } ?: "") },
        )
    }

    fun parseMacStatus(m: Message): MacStatus = MacStatus(
        name = m.str("name") ?: "", model = m.str("model") ?: "",
        battery = ((m.header["battery"] as? JsonPrimitive)?.takeIf { it !is JsonNull })?.let { it.intOrNull ?: it.doubleOrNull?.toInt() }?.coerceIn(0, 100),
        charging = m.bool("charging") == true, locked = m.bool("locked") == true, displayAsleep = m.bool("displayAsleep") == true,
    )

    fun parseMacResult(m: Message): MacResult? {
        val req = m.str("req") ?: return null
        return MacResult(req, m.bool("ok") == true, m.str("error")?.takeIf { it.isNotBlank() }, m.str("note")?.takeIf { it.isNotBlank() })
    }

    fun parseShortcuts(m: Message): ShortcutList? {
        val req = m.str("req") ?: return null
        val err = m.str("error")?.takeIf { it.isNotBlank() }
        if (err != null) return ShortcutList(req, null, err)
        val items = m.arr("items")?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content?.takeIf { s -> s.isNotBlank() } } ?: emptyList()
        return ShortcutList(req, items, null)
    }
}

/**
 * Turns user intent into `in.*` messages, with the one stateful rule: the ⌘ toggle is armed for exactly the next key,
 * character or shortcut and then clears itself, like a one-shot modifier.
 */
class RemoteInput(private val send: (Message) -> Unit) {
    @Volatile var cmdArmed = false
        private set
    private val listeners = java.util.concurrent.CopyOnWriteArrayList<(Boolean) -> Unit>()

    fun onCmdChanged(l: (Boolean) -> Unit) { listeners += l }

    fun setCmd(on: Boolean) { cmdArmed = on; listeners.forEach { it(on) } }

    private fun mods(extra: Set<String>): Set<String> = if (cmdArmed) extra + "cmd" else extra

    private fun consumeCmd() { if (cmdArmed) setCmd(false) }

    /** A named key or one character from the special-key row. Not for shortcuts that carry their own modifiers. */
    fun key(key: String, mods: Set<String> = emptySet()) {
        if (!RemoteKeys.valid(key)) return
        send(RemoteWire.key(key, mods(mods)))
        consumeCmd()
    }

    /** ⌘C, ⌘Tab, Mission Control: fixed modifiers, and the toggle is left alone. */
    fun shortcut(key: String, mods: Set<String>) {
        if (!RemoteKeys.valid(key)) return
        send(RemoteWire.key(key, mods))
    }

    /** What the soft keyboard produced. With ⌘ armed, the first character becomes ⌘+that character. */
    fun ops(ops: List<KeyOp>) {
        for (op in ops) when (op) {
            is KeyOp.Backspace -> key("backspace")
            is KeyOp.Enter -> key("enter")
            is KeyOp.Tab -> key("tab")
            is KeyOp.Text -> {
                var rest = op.text
                if (cmdArmed && rest.isNotEmpty()) {
                    val first = rest.codePointAt(0)
                    val n = Character.charCount(first)
                    key(rest.substring(0, n).lowercase())
                    rest = rest.substring(n)
                }
                if (rest.isNotEmpty()) send(RemoteWire.text(rest))
            }
        }
    }

    fun media(action: String) { if (action in RemoteKeys.MEDIA) send(RemoteWire.media(action)) }
}

/** Kind text for `mac.result` problems and for things that go wrong before a request is even sent. */
object MacMessages {
    fun label(action: String, name: String? = null): String = when (action) {
        "lock" -> "lock your Mac"
        "sleep", "displaysleep" -> "put your Mac to sleep"
        "ring" -> "ring your Mac"
        "ringstop" -> "stop the ringing"
        "shortcut" -> if (name != null) "run “$name”" else "run that Shortcut"
        else -> "do that"
    }

    const val DISPLAY_SLEEP_NOTE = "Screen turned off, but may not be locked"

    /**
     * null when everything went fine. A lock that fell back to turning the screen off (`ok:true`, `note:"displaysleep"`)
     * still gets one honest line, since the Mac may not be locked. [error] with `ok:true` is also worth a line.
     */
    fun failure(action: String, name: String?, ok: Boolean, error: String?, note: String? = null): String? {
        if (ok && error == null) return if (action == "lock" && note == "displaysleep") DISPLAY_SLEEP_NOTE else null
        val what = label(action, name)
        val e = error?.lowercase().orEmpty()
        return when {
            e.contains("accessib") || e.contains("permission") ->
                "Couldn't $what. Allow Mydroid in Accessibility on your Mac"
            ok && action == "lock" -> DISPLAY_SLEEP_NOTE
            e.contains("not found") || e.contains("not_found") || e.contains("no such") || e.contains("couldn't find") ->
                "Couldn't $what. It's gone from your Mac"
            e.contains("busy") -> "Couldn't $what. Your Mac is busy"
            e.contains("timeout") || e.contains("timed out") -> "Couldn't $what. Your Mac didn't answer"
            action == "shortcut" -> "Couldn't $what. Check it in Shortcuts"
            else -> "Couldn't $what. Try again in a moment."
        }
    }

    const val AWAY = "Your Mac is away"
}

/** Starred Shortcuts, shown as chips on the Your Mac card. Stored as one name per line. */
object Favorites {
    fun decode(raw: String?): List<String> = (raw ?: "").split('\n').map { it.trim() }.filter { it.isNotEmpty() }.distinct()
    fun encode(items: List<String>): String = items.joinToString("\n")
    fun toggle(items: List<String>, name: String): List<String> = if (name in items) items - name else items + name
}
