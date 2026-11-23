package com.mydroid.android.mac

import android.app.Application
import android.os.Handler
import android.os.Looper
import com.mydroid.android.data.Store
import com.mydroid.protocol.*
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** What the Home screen and the Remote screen know about the Mac beyond the connection itself (PROTOCOL.md 10, 11). */
data class MacUi(
    /** `remote.state`; null until the Mac has said. An older Mac never does, and then nothing is blocked. */
    val remote: RemoteState? = null,
    val status: MacStatus? = null,
    /** The Shortcuts list for the sheet; null until it has loaded. */
    val shortcuts: List<String>? = null,
    val shortcutsLoading: Boolean = false,
    val shortcutsError: String? = null,
    val favorites: List<String> = emptyList(),
    /** The Ring button is in its "Stop" state. Cleared on its own after the Mac's 60 s limit. */
    val ringing: Boolean = false,
)

/**
 * Quick actions, Mac status and Shortcuts (PROTOCOL.md 11) and the Mac's side of Remote (10): `remote.state`,
 * `mac.status`, `mac.result` and `mac.shortcuts` come in here; lock, sleep, ring and shortcuts go out from here.
 * Everything is request/response by `req`, so a late answer can't be mistaken for another one.
 */
class MacControl(
    private val app: Application,
    private val store: Store,
    private val send: (Message) -> Boolean,
    private val isConnected: () -> Boolean,
    private val current: () -> MacUi,
    private val update: ((MacUi) -> MacUi) -> Unit,
    private val notice: (String) -> Unit,
    private val appVisible: () -> Boolean,
) {
    private class Pending(val action: String, val name: String?)

    private val pending = ConcurrentHashMap<String, Pending>()
    @Volatile private var shortcutsReq: String? = null
    private val main = Handler(Looper.getMainLooper())
    private val ringTimeout = Runnable { update { it.copy(ringing = false) } }

    fun handles(type: String) = type == "remote.state" || type == "mac.status" || type == "mac.result" || type == "mac.shortcuts"

    fun onMessage(m: Message) {
        when (m.type) {
            "remote.state" -> onRemoteState(RemoteWire.parseRemoteState(m))
            "mac.status" -> { val st = RemoteWire.parseMacStatus(m); update { it.copy(status = st) } }
            "mac.result" -> RemoteWire.parseMacResult(m)?.let(::onResult)
            "mac.shortcuts" -> RemoteWire.parseShortcuts(m)?.let(::onShortcuts)
        }
    }

    private fun onRemoteState(rs: RemoteState) {
        val before = current().remote?.presenting
        update { it.copy(remote = rs) }
        val p = rs.presenting
        when {
            p == null -> PresenterNotice.cancel(app)
            // Only when it starts (or the app changes), and only if the app isn't already in front.
            before?.app != p.app && !appVisible() -> PresenterNotice.post(app, p.app)
        }
    }

    private fun onResult(r: MacResult) {
        val p = pending.remove(r.req) ?: return
        if (p.action == "ring" && !r.ok) { main.removeCallbacks(ringTimeout); update { it.copy(ringing = false) } }
        MacMessages.failure(p.action, p.name, r.ok, r.error, r.note)?.let(notice)
    }

    private fun onShortcuts(l: ShortcutList) {
        if (l.req != shortcutsReq) return
        shortcutsReq = null
        update {
            if (l.items != null) it.copy(shortcuts = l.items, shortcutsLoading = false, shortcutsError = null)
            else it.copy(shortcutsLoading = false, shortcutsError = "Couldn't read your Shortcuts. Open the Shortcuts app on your Mac once, then try again.")
        }
    }

    fun onConnected() = update { it.copy(favorites = store.favoriteShortcuts) }

    /** The session ended: whatever the Mac last said is no longer true. */
    fun onDisconnected() {
        main.removeCallbacks(ringTimeout)
        pending.clear(); shortcutsReq = null
        PresenterNotice.cancel(app)
        update { it.copy(remote = null, status = null, ringing = false, shortcutsLoading = false) }
    }

    // ---------------------------------------------------------------- actions (from the UI)

    private fun act(action: String, name: String? = null): Boolean {
        if (!isConnected()) { notice(MacMessages.AWAY); return false }
        val req = UUID.randomUUID().toString()
        pending[req] = Pending(action, name)
        if (pending.size > 20) pending.keys.firstOrNull()?.let { pending.remove(it) }
        return send(RemoteWire.macAction(req, action, name)).also { if (!it) pending.remove(req) }
    }

    fun lock() { act("lock") }
    fun sleep() { act("sleep") }

    fun toggleRing() {
        if (current().ringing) {
            main.removeCallbacks(ringTimeout)
            update { it.copy(ringing = false) }
            act("ringstop")
        } else if (act("ring")) {
            update { it.copy(ringing = true) }
            main.postDelayed(ringTimeout, 61_000) // the Mac stops by itself after 60 s
        }
    }

    fun runShortcut(name: String) { act("shortcut", name) }

    fun loadShortcuts() {
        if (!isConnected()) { update { it.copy(shortcutsError = MacMessages.AWAY, shortcutsLoading = false) }; return }
        val req = UUID.randomUUID().toString()
        shortcutsReq = req
        update { it.copy(shortcutsLoading = true, shortcutsError = null) }
        if (!send(RemoteWire.shortcutsGet(req))) update { it.copy(shortcutsLoading = false, shortcutsError = MacMessages.AWAY) }
    }

    fun toggleFavorite(name: String) {
        val next = Favorites.toggle(current().favorites, name)
        store.favoriteShortcuts = next
        update { it.copy(favorites = next) }
    }

    /** The phone opened Remote and the Mac lacks Accessibility: ask it to show its prompt. */
    fun remoteAsk() { send(RemoteWire.remoteAsk()) }

    /** The app came to the front: the clicker shortcut isn't needed any more. */
    fun onAppVisible() = PresenterNotice.cancel(app)
}
