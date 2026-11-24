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
    /** When `remote.state` last arrived (ms since 1970). The Mac repeats it whenever the phone asks, so this says how fresh the answer is. */
    val status: MacStatus? = null,
    /** The Shortcuts list for the sheet; null until it has loaded. */
    val shortcuts: List<String>? = null,
    val shortcutsLoading: Boolean = false,
    val shortcutsError: String? = null,
    val favorites: List<String> = emptyList(),
    /** The Ring button is in its "Stop" state. Cleared on its own after the Mac's 60 s limit. */
    val ringing: Boolean = false,
    /** Apps on the Mac, for the Open tab (PROTOCOL.md 16.1). Null until asked for. */
    val apps: AppsUi? = null,
    /** `present.state`: where the slideshow is (16.2). Only while the Present tab is open. */
    val present: PresentInfo? = null,
    /** `mac.media`: what Music or Spotify is playing on the Mac (16.3). Only while the Playing tab is open. */
    val media: MacMediaState? = null,
)

data class AppsUi(val running: List<MacApp>, val installed: List<MacApp>, val loading: Boolean = false, val error: String? = null)

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
    @Volatile private var appsReq: String? = null
    private val main = Handler(Looper.getMainLooper())
    private val ringTimeout = Runnable { update { it.copy(ringing = false) } }

    fun handles(type: String) = type == "remote.state" || type == "mac.status" || type == "mac.result" || type == "mac.shortcuts" ||
        type == "mac.apps" || type == "present.state" || type == "mac.media"

    fun onMessage(m: Message) {
        when (m.type) {
            "remote.state" -> onRemoteState(RemoteWire.parseRemoteState(m))
            "mac.status" -> { val st = RemoteWire.parseMacStatus(m); update { it.copy(status = st) } }
            "mac.result" -> RemoteWire.parseMacResult(m)?.let(::onResult)
            "mac.shortcuts" -> RemoteWire.parseShortcuts(m)?.let(::onShortcuts)
            "mac.apps" -> RemoteWire.parseApps(m)?.let(::onApps)
            "present.state" -> { val p = RemoteWire.parsePresent(m); update { it.copy(present = p) } }
            "mac.media" -> { val st = RemoteWire.parseMacMedia(m); update { it.copy(media = st.withArtFrom(it.media)) } }
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

    private fun onApps(l: AppsList) {
        if (l.req != appsReq) return
        appsReq = null
        update { it.copy(apps = AppsUi(l.running, l.installed)) }
    }

    fun onConnected() = update { it.copy(favorites = store.favoriteShortcuts) }

    /** The session ended: whatever the Mac last said is no longer true. */
    fun onDisconnected() {
        main.removeCallbacks(ringTimeout)
        pending.clear(); shortcutsReq = null; appsReq = null
        PresenterNotice.cancel(app)
        update { it.copy(remote = null, status = null, ringing = false, shortcutsLoading = false, apps = null, present = null, media = null) }
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

    // ---------------------------------------------------------------- PROTOCOL.md 16

    /** Sends a request whose answer is a `mac.result`; a failure is told to the user by [MacMessages]. */
    private fun request(action: String, name: String?, build: (req: String) -> Message): Boolean {
        if (!isConnected()) { notice(MacMessages.AWAY); return false }
        val req = UUID.randomUUID().toString()
        pending[req] = Pending(action, name)
        if (pending.size > 20) pending.keys.firstOrNull()?.let { pending.remove(it) }
        return send(build(req)).also { if (!it) pending.remove(req) }
    }

    fun loadApps() {
        if (!isConnected()) return
        val req = UUID.randomUUID().toString()
        appsReq = req
        if (current().apps == null) update { it.copy(apps = AppsUi(emptyList(), emptyList(), loading = true)) }
        send(RemoteWire.appsGet(req))
    }

    fun launchApp(id: String, name: String) { request("launch", name) { RemoteWire.launch(it, id) } }
    fun openFile(root: String, path: String, name: String) { request("open", name) { RemoteWire.open(it, root, path) } }
    fun startPresentation(root: String, path: String, name: String, play: Boolean) { request("present", name) { RemoteWire.presentStart(it, root, path, play) } }

    /** The Present tab is on screen (or not): the Mac reads the slide only while someone is looking. */
    fun watchPresent(on: Boolean) {
        if (!isConnected()) return
        if (!on) update { it.copy(present = null) }
        send(RemoteWire.presentWatch(on))
    }

    fun watchMedia(on: Boolean) {
        if (!isConnected()) return
        if (!on) update { it.copy(media = null) }
        send(RemoteWire.mediaWatch(on))
    }

    fun mediaCommand(m: Message) { if (isConnected()) send(m) }

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
