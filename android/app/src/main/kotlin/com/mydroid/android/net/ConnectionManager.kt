package com.mydroid.android.net

import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.system.Os
import android.system.OsConstants
import android.provider.OpenableColumns
import android.provider.Settings as AndroidSettings
import android.webkit.MimeTypeMap
import com.mydroid.android.*
import com.mydroid.android.calls.CallControl
import com.mydroid.android.calls.CallMonitor
import com.mydroid.android.clip.ClipAccessibilityService
import com.mydroid.android.clip.Clipboard
import com.mydroid.android.data.Settings
import com.mydroid.android.data.Store
import com.mydroid.android.files.FileLedger
import com.mydroid.android.files.IncomingFiles
import com.mydroid.android.files.MacFiles
import com.mydroid.android.find.FindMyPhone
import com.mydroid.android.link.LinkOpener
import com.mydroid.android.mac.MacControl
import com.mydroid.android.mac.MacUi
import com.mydroid.android.mac.PresenterNotice
import com.mydroid.android.remote.RemoteApi
import com.mydroid.android.walkaway.WalkAway
import com.mydroid.android.walkaway.WalkAwayAdvertiser
import com.mydroid.android.media.MediaBridge
import com.mydroid.android.presence.Presence
import com.mydroid.android.callaudio.CallAudioSetup
import com.mydroid.android.callaudio.CallAudioWatcher
import com.mydroid.android.fix.Fixer
import com.mydroid.android.notif.NotifBridge
import com.mydroid.android.photos.MediaStoreSource
import com.mydroid.android.photos.PhotoCatchUpWorker
import com.mydroid.android.photos.PhotoQueue
import com.mydroid.android.photos.PhotoSync
import com.mydroid.protocol.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.put
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

enum class Link { Unpaired, Connecting, Confirm, Connected, Searching }

data class UiState(
    val link: Link = Link.Unpaired,
    val macName: String = "your Mac",
    val code: String? = null,
    val lastSeen: Long = 0,
    val settings: Settings? = null,
    val report: FeatureReport = FeatureReport(),
    val photosWaiting: Int = 0,
    val setupDone: Boolean = false,
    val message: String? = null,
    val oemOpenedAt: Long = 0,
    /** Live, queued and recent transfers for the Home screen. */
    val transfers: com.mydroid.android.transfers.TransfersState = com.mydroid.android.transfers.TransfersState(),
    /** A one-line result for the Home screen's snackbar ("Sent to your Mac"). */
    val notice: String? = null,
    /** The Mac's side of Remote and Quick actions (PROTOCOL.md 10, 11). */
    val mac: MacUi = MacUi(),
    /** The notification asked for this Remote mode ("presenter"); the UI opens it and then consumes it. */
    val openRemote: String? = null,
    /** Authenticator counts and settings. Never secrets or codes. */
    val auth: com.mydroid.android.auth.AuthUi = com.mydroid.android.auth.AuthUi(),
)

private class SessionCtx(val session: ClientSession, val engine: TransferEngine) {
    var batteryReceiver: BroadcastReceiver? = null
}

/**
 * Owns the connection to the Mac: discovery, racing, backoff, the session, feature wiring and
 * everything the UI observes. One instance per process, created by [MydroidApp].
 */
private const val TAG = "Mydroid"
private const val MAX_ATTEMPTS = 5
private const val ATTEMPT_WINDOW_MS = 10_000L
private const val KNOWN_WINDOW_MS = 2_500L
private const val OUTBOX_TTL_MS = 10 * 60_000L

class ConnectionManager(private val app: Application) {
    val store = Store(app)
    private val queue = PhotoQueue(app)
    val photos = PhotoSync(app, store, queue)
    @Volatile var settings: Settings = store.settings
        private set
    val notifs = NotifBridge(app, { send(it) }, { settings.notifications && isConnected })
    val media = MediaBridge(app) { send(it) }
    /** BLE presence policy (PROTOCOL.md 7.1): when the service and retries may run. */
    private val presence = PresenceMachine()
    @Volatile private var scanRegistered = false
    private val calls = CallMonitor(app) { send(it) }
    private val callControl = CallControl(app)
    val transfers = com.mydroid.android.transfers.Transfers(app)
    private val incoming = IncomingFiles(app) { name, size -> transfers.recordFile(com.mydroid.android.transfers.Direction.FromMac, name, size) }
    private val ledger = FileLedger(app)
    private val cm = app.getSystemService(ConnectivityManager::class.java)
    private val callAudioWatcher = CallAudioWatcher(app) {
        CallAudioSetup.keepAlive(app, settings)
        refreshFeatures()
    }

    private val _state = MutableStateFlow(
        UiState(
            link = if (store.isPaired) Link.Searching else Link.Unpaired,
            macName = store.macName, lastSeen = store.lastSeen,
            settings = if (store.hasSettings) store.settings else null,
            setupDone = store.setupDone, photosWaiting = queue.count.value, oemOpenedAt = store.oemOpenedAt,
            mac = MacUi(favorites = store.favoriteShortcuts),
        ),
    )
    val state: StateFlow<UiState> get() = _state

    private val lock = Object()
    private var wake = false
    @Volatile private var started = false
    @Volatile private var pending: PairingUrl? = null
    @Volatile private var sess: SessionCtx? = null
    @Volatile private var racer: CandidateRacer<SecureChannel>? = null
    private val backoff = Backoff()
    @Volatile private var backoffReset = false
    private var failures = 0
    private var workerScheduled = false
    /** True while the supervisor has given up and is parked until a trigger (network, screen, app open). */
    @Volatile private var dormant = false
    @Volatile private var screenOn = true
    private val mainHandler = Handler(Looper.getMainLooper())
    /** Single writer so callers on the main thread (UI, NotificationListenerService) never touch the socket. */
    private val writer = Executors.newSingleThreadExecutor { Thread(it, "mydroid-writer").apply { isDaemon = true } }
    private val uploader = Executors.newSingleThreadExecutor { Thread(it, "mydroid-photos").apply { isDaemon = true } }
    private val fileExec = Executors.newSingleThreadExecutor { Thread(it, "mydroid-files").apply { isDaemon = true } }
    private val transferLock = Any()
    /** SMS, photo library, call log and dialling requests from the Mac (PROTOCOL.md 7.5 to 7.8). Workers, never the reader thread. */
    /** The Mac's shared folders behind the Files app (PROTOCOL.md 9); `MacDocumentsProvider` reads it. */
    val macFiles = MacFiles(app, store, { send(it) }, { sess?.engine }, transferLock, { isConnected })
    /** Authenticator vault and the Mac's code requests (PROTOCOL.md 14). Secrets never leave it except one approved code. */
    val auth = com.mydroid.android.auth.AuthController(app, { send(it) }, { store.macName }, { presence.isEnabled() && presence.isPresent() }, { transfers.record(it) }, { visible })
    val requests = RequestRouter(app, { settings }, { send(it) }, { sess?.engine }, transferLock, macFiles)
    private val uploading = AtomicBoolean(false)
    private val again = AtomicBoolean(false)
    @Volatile private var lastFeatureJson: String? = null
    private var lastDevice: String? = null

    val isConnected: Boolean get() = sess?.session?.state == SessionState.READY

    // ---------------------------------------------------------------- Mac control, Remote, walk-away lock

    @Volatile private var visible = false
    /** Quick actions, Mac status and Shortcuts; also the Mac's `remote.state` (PROTOCOL.md 10, 11). */
    val mac = MacControl(app, store, { send(it) }, { isConnected }, { _state.value.mac }, { f -> _state.update { it.copy(mac = f(it.mac)) } }, { postNotice(it) }, { visible })
    private val walkAway = WalkAwayAdvertiser(app)
    /** Input has its own writer so a stalled socket never queues behind file chunks; stale moves are dropped, not queued. */
    private val inputWriter = Executors.newSingleThreadExecutor { Thread(it, "mydroid-input").apply { isDaemon = true; priority = Thread.NORM_PRIORITY + 1 } }
    private val inputQueued = java.util.concurrent.atomic.AtomicInteger(0)

    private fun sendInput(m: Message) {
        val s = sess?.session?.takeIf { it.state == SessionState.READY } ?: return
        val lossy = m.type == "in.move" || m.type == "in.scroll" || m.type == "in.laser"
        if (lossy && inputQueued.get() > 40) return
        inputQueued.incrementAndGet()
        inputWriter.execute {
            try { s.send(m) } catch (e: IOException) { /* the session is closing; the supervisor handles it */ } finally { inputQueued.decrementAndGet() }
        }
    }

    /** The Remote screen's view of the app (PROTOCOL.md 10). */
    val remoteApi = object : RemoteApi {
        override fun send(m: Message) = sendInput(m)
        override fun ask() = mac.remoteAsk()
        override fun volumeKeys(handler: ((up: Boolean) -> Unit)?) { com.mydroid.android.remote.VolumeKeys.handler = handler }
        override fun loadApps() = mac.loadApps()
        override fun launchApp(app: com.mydroid.protocol.MacApp) = mac.launchApp(app.id, app.name)
        override fun openFile(hit: com.mydroid.protocol.FsHit) = mac.openFile(hit.root, hit.path, hit.entry.name)
        override fun startPresentation(hit: com.mydroid.protocol.FsHit, play: Boolean) = mac.startPresentation(hit.root, hit.path, com.mydroid.protocol.Decks.title(hit.entry.name), play)
        override fun watchPresent(on: Boolean) = mac.watchPresent(on)
        override fun watchMedia(on: Boolean) = mac.watchMedia(on)
        override fun mediaCommand(m: Message) = mac.mediaCommand(m)
        override fun openLink(url: String) { postNotice(sendText(url, "remote")) }
        override fun findFiles(query: String): List<com.mydroid.protocol.FsHit>? {
            if (!isConnected) return null
            val f = if (query.isBlank()) macFiles.client.recent() else macFiles.client.search(query.trim())
            return runCatching { f.get(20, java.util.concurrent.TimeUnit.SECONDS) }.getOrNull()?.takeIf { it.ok }?.value
        }
    }

    /** MainActivity is in front or not. A presentation notification is pointless while the app is open. */
    fun setVisible(v: Boolean) {
        visible = v
        if (v) mac.onAppVisible()
    }

    fun requestRemote(mode: String) {
        PresenterNotice.cancel(app)
        _state.update { it.copy(openRemote = mode) }
    }
    fun consumeOpenRemote() = _state.update { it.copy(openRemote = null) }

    /** Advertise the phone's walk-away beacon only while everything says so: setting on, paired, connected, service running, permission, Bluetooth. */
    fun refreshWalkAway() {
        val want = settings.walkAway && store.isPaired && isConnected && ConnectionService.running &&
            WalkAway.status(app, settings) == com.mydroid.android.walkaway.WalkAwayStatus.On
        walkAway.setActive(want)
    }

    init {
        // Photo queue size drives the "3 photos waiting" row.
        Thread({ queue.count.collectBlocking { n -> _state.update { it.copy(photosWaiting = n) } } }, "mydroid-qcount").apply { isDaemon = true }.start()
        Thread({ transfers.state.collectBlocking { t -> _state.update { it.copy(transfers = t) } } }, "mydroid-transfers").apply { isDaemon = true }.start()
        Thread({ auth.ui.collectBlocking { u -> _state.update { it.copy(auth = u) } } }, "mydroid-auth-ui").apply { isDaemon = true }.start()
        photos.onNewPhotos = { kickPhotoUpload() }
        notifs.setMuted(settings.mutedApps)
    }

    // ---------------------------------------------------------------- lifecycle

    @Synchronized
    fun start() {
        if (started) return
        started = true
        screenOn = app.getSystemService(PowerManager::class.java).isInteractive
        registerNetworkCallback()
        registerScreenReceiver()
        registerBluetoothReceiver()
        refreshPresence(force = true)
        Thread(::supervise, "mydroid-supervisor").apply { isDaemon = true }.start()
        refreshFeatures()
    }

    private fun poke() = synchronized(lock) { wake = true; lock.notifyAll() }

    /** [ms] == 0 waits until [poke]; no timer, so an idle supervisor costs nothing. */
    private fun waitFor(ms: Long) = synchronized(lock) {
        if (!wake) lock.wait(ms)
        wake = false
    }

    /**
     * Park until something changes: a Wi-Fi/ethernet network, screen on / user present, the app opening,
     * pairing. Nothing is dialled and no discovery runs while parked.
     */
    private fun goDormant(why: String) {
        android.util.Log.i(TAG, "idle: $why; waiting for network change, screen on or app open")
        dormant = true
        try {
            waitFor(0)
        } finally {
            dormant = false
        }
    }

    /** Something that might make the Mac reachable again happened. No-op unless we gave up. */
    fun wakeUp(reason: String) {
        if (!dormant) return
        android.util.Log.i(TAG, "wake: $reason")
        backoffReset = true
        poke()
    }

    private fun lanAvailable(): Boolean {
        val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return false) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
    }

    private fun supervise() {
        while (true) {
            try {
                val p = pending
                if (p != null) {
                    pending = null
                    runPairing(p)
                    continue
                }
                if (!store.isPaired) {
                    waitFor(0)
                    continue
                }
                if (backoffReset) { backoff.reset(); failures = 0; backoffReset = false }
                if (presence.parked(System.currentTimeMillis())) {
                    goDormant("Mac not nearby (Bluetooth) and no session for 2 min; no retries or discovery")
                    continue
                }
                if (!lanAvailable()) {
                    goDormant("no Wi-Fi or ethernet")
                    continue
                }
                val connected = runPaired()
                if (connected) {
                    backoff.reset(); failures = 0; waitFor(1_000)
                } else if (++failures >= MAX_ATTEMPTS) {
                    failures = 0; backoff.reset()
                    goDormant("Mac unreachable after $MAX_ATTEMPTS attempts")
                } else {
                    waitFor(backoff.nextDelay())
                }
            } catch (e: Throwable) {
                android.util.Log.w(TAG, "supervisor error", e)
                waitFor(2_000)
            }
        }
    }

    // ---------------------------------------------------------------- BLE presence (PROTOCOL.md 7.1)

    private val parkCheck = Runnable { checkPark() }
    private val lostFallback = Runnable { onMacNearby(false) }

    /** The foreground service may run: always without presence, else unless the Mac has been gone for 2 min. */
    fun serviceAllowed(): Boolean = !presence.parked(System.currentTimeMillis())

    /**
     * Re-read whether presence can drive the lifecycle (permission, association, Bluetooth on, paired) and
     * (re)register the scan. Called on start, app open, boot/update, Bluetooth on and after the association dialog.
     */
    fun refreshPresence(force: Boolean) {
        if (store.isPaired) Presence.dropPlainIfWatch(app)
        if (store.isPaired && android.os.Build.VERSION.SDK_INT >= 35) {
            mainHandler.post { notifs.listener?.refreshCompanionAccess() }
        }
        val now = System.currentTimeMillis()
        val on = store.isPaired && Presence.ready(app)
        val was = presence.isEnabled()
        presence.setEnabled(on, now)
        if (on) {
            if (force || !scanRegistered) scanRegistered = Presence.register(app).ok
        } else if (scanRegistered || was) {
            Presence.unregister(app); scanRegistered = false
        }
        if (was != on) {
            android.util.Log.i(TAG, "presence ${if (on) "on: service follows the Mac's Bluetooth presence" else "off: always-on behaviour"}")
            if (!on) unpark("presence off", force = true)
        }
        scheduleParkCheck()
        if (force) _state.update { it.copy(report = Features.report(app, settings, store.callAudioEver, store.instantCopy)) }
    }

    /** A BLE scan callback: the Mac's UUID appeared ([found]) or went away. */
    fun onMacNearby(found: Boolean, viaAllMatches: Boolean = false) {
        android.util.Log.i(TAG, "mac nearby=$found")
        if (found) {
            presence.onFound()
            mainHandler.removeCallbacks(lostFallback)
            // ALL_MATCHES fallback has no MATCH_LOST: treat 90 s of silence as lost.
            if (viaAllMatches) mainHandler.postDelayed(lostFallback, 90_000)
            if (store.isPaired) {
                start()
                ConnectionService.start(app)
                if (!isConnected) { backoffReset = true; poke() }
            }
        } else {
            presence.onLost(System.currentTimeMillis())
        }
        scheduleParkCheck()
    }

    private fun scheduleParkCheck() {
        mainHandler.removeCallbacks(parkCheck)
        presence.msUntilPark(System.currentTimeMillis())?.let { mainHandler.postDelayed(parkCheck, it + 100) }
    }

    private fun checkPark() {
        if (!store.isPaired) return
        if (presence.parked(System.currentTimeMillis())) {
            android.util.Log.i(TAG, "park: Mac gone and no session for 2 min; stopping service, retries and NSD")
            racer?.cancel()
            ConnectionService.stop(app)
            poke() // the supervisor sees the parked state and sleeps with no timer
        } else scheduleParkCheck()
    }

    /** Found elsewhere, Wi-Fi appeared, unlock, app open: leave the parked state for another 2 min window. */
    fun unpark(reason: String, force: Boolean = false) {
        val now = System.currentTimeMillis()
        if (!force && !presence.parked(now)) return
        presence.wake(now)
        android.util.Log.i(TAG, "unpark: $reason")
        scheduleParkCheck()
        if (store.isPaired) {
            ConnectionService.start(app)
            if (!isConnected) { backoffReset = true; poke() }
        }
    }

    private fun registerBluetoothReceiver() {
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                when (i.getIntExtra(android.bluetooth.BluetoothAdapter.EXTRA_STATE, -1)) {
                    android.bluetooth.BluetoothAdapter.STATE_ON -> { refreshPresence(force = true); refreshFeatures() }
                    android.bluetooth.BluetoothAdapter.STATE_OFF -> { refreshPresence(force = false); refreshWalkAway() }
                }
            }
        }
        app.registerReceiver(r, IntentFilter(android.bluetooth.BluetoothAdapter.ACTION_STATE_CHANGED))
    }

    // ---------------------------------------------------------------- pairing

    fun startPairing(url: PairingUrl) {
        android.util.Log.i(TAG, "startPairing mac=${url.macId} addrs=${url.addresses}")
        pending = url
        presence.wake(System.currentTimeMillis())
        _state.update { it.copy(link = Link.Connecting, message = null, code = null) }
        racer?.cancel()
        sess?.session?.close()
        poke()
    }

    fun cancelPairing() {
        pending = null
        racer?.cancel()
        sess?.session?.close()
        _state.update { if (store.isPaired) it else it.copy(link = Link.Unpaired, code = null) }
    }

    private fun runPairing(p: PairingUrl) {
        pairingInFlight = true
        try {
            runPairingInner(p)
        } catch (e: Exception) {
            android.util.Log.w(TAG, "pairing failed", e)
            if (_state.value.link == Link.Connecting || _state.value.link == Link.Confirm) {
                _state.update { it.copy(link = if (store.isPaired) Link.Searching else Link.Unpaired, code = null, message = "Pairing failed. Scan the code again.") }
            }
        } finally {
            pairingInFlight = false
        }
    }

    private fun runPairingInner(p: PairingUrl) {
        val ltk = Keys.ltkFromSecret(p.secret)
        val r = CandidateRacer { hp -> Handshake.connect(hp, store.phoneId, p.macId, true, ltk, tuneSocket = ::tuneKeepAlive) }
        racer = r
        p.addresses.forEach { r.add(it) }
        android.util.Log.i(TAG, "pairing: dialing ${p.addresses}")
        val ch = r.await(12_000)
        racer = null
        pairingInFlight = false // dialing is over; network changes may now drop the session as usual
        android.util.Log.i(TAG, "pairing: dial result=${ch != null} errors=${r.lastErrors}")
        if (ch == null) {
            r.cancel()
            _state.update { it.copy(link = if (store.isPaired) Link.Searching else Link.Unpaired, message = "Can't reach your Mac. Use the same Wi-Fi.") }
            return
        }
        runSession(ch, pairingInfo = p to ltk)
    }

    fun unpair() {
        val s = sess
        writer.execute {
            // Tell the Mac first (off the main thread), then forget locally.
            if (s != null) runCatching { s.session.send(Message.of("unpair")) }
            forgetPairing("You're unpaired. Scan a new code whenever you're ready.")
        }
    }

    private fun forgetPairing(message: String?) {
        sess?.session?.close()
        racer?.cancel()
        store.clearPairing()
        macFiles.onUnpaired()
        queue.clear(); transfers.clearAll()
        settings = Settings()
        photos.stopObserving(); calls.stop(); PhotoCatchUpWorker.cancel(app)
        media.setEnabled(false); notifs.setMuted(emptySet()); requests.sms.setObserving(false)
        presence.setEnabled(false, System.currentTimeMillis()); scanRegistered = false
        walkAway.setActive(false); mac.onDisconnected()
        Presence.unregister(app); Presence.disassociateAll(app)
        ConnectionService.stop(app)
        lastFeatureJson = null
        _state.update { UiState(link = Link.Unpaired, message = message, auth = auth.ui.value) }
        poke()
    }

    // ---------------------------------------------------------------- connecting

    /** @return true if a session was established. */
    private fun runPaired(): Boolean {
        val creds = store.credentials() ?: return false
        _state.update { if (it.link == Link.Connected) it else it.copy(link = Link.Searching) }
        val r = CandidateRacer { hp -> Handshake.connect(hp, creds.phoneId, creds.macId, false, creds.ltk, tuneSocket = ::tuneKeepAlive) }
        racer = r
        // Known addresses first: on the same Wi-Fi this connects in milliseconds and never touches multicast.
        val known = listOfNotNull(store.lastGood) + store.addresses
        known.forEach { r.add(it) }
        var ch = if (known.isEmpty()) null else r.await(KNOWN_WINDOW_MS) { true }
        if (ch == null && store.isPaired && !r.isCancelled) {
            // Bonjour only as a bounded fallback (the MulticastLock is a real drain): whole attempt <= 10 s.
            val discovery = Discovery(app, creds.macId) { r.add(it) }
            discovery.start()
            try {
                ch = r.await(ATTEMPT_WINDOW_MS - if (known.isEmpty()) 0 else KNOWN_WINDOW_MS) { store.isPaired }
            } finally {
                discovery.stop()
            }
        }
        racer = null
        android.util.Log.i(TAG, "reconnect: result=${ch != null} errors=${r.lastErrors.size}")
        if (ch == null) {
            r.cancel(); return false
        }
        if (!store.isPaired) { ch.close(); return false }
        store.lastGood = ch.remote
        runSession(ch, pairingInfo = null)
        return true
    }

    /** TCP keepalive: first probe after 120 s idle, then every 30 s, give up after 4 (the JVM can't set these). */
    private fun tuneKeepAlive(socket: java.net.Socket) {
        val pfd = ParcelFileDescriptor.fromSocket(socket)
        try {
            val fd = pfd.fileDescriptor
            Os.setsockoptInt(fd, OsConstants.IPPROTO_TCP, 4 /* TCP_KEEPIDLE */, 120)
            Os.setsockoptInt(fd, OsConstants.IPPROTO_TCP, 5 /* TCP_KEEPINTVL */, 30)
            Os.setsockoptInt(fd, OsConstants.IPPROTO_TCP, 6 /* TCP_KEEPCNT */, 4)
        } finally {
            pfd.close() // closes the dup only
        }
    }

    private fun deviceIdentity(): DeviceIdentity {
        val name = runCatching { AndroidSettings.Global.getString(app.contentResolver, "device_name") }.getOrNull()?.takeIf { it.isNotBlank() } ?: Build.MODEL
        return DeviceIdentity(name, Build.MODEL, Build.VERSION.SDK_INT)
    }

    private fun runSession(ch: SecureChannel, pairingInfo: Pair<PairingUrl, ByteArray>?) {
        lateinit var ctx: SessionCtx
        lateinit var engine: TransferEngine
        val listener = object : SessionListener {
            override fun onConfirmCode(code: String) {
                android.util.Log.i(TAG, "confirm code shown")
                _state.update { it.copy(link = Link.Confirm, code = Keys.displayCode(code)) }
            }

            override fun onReady(pairing: Boolean, macName: String) {
                if (pairing && pairingInfo != null) {
                    val (url, ltk) = pairingInfo
                    store.savePairing(url.macId, macName.ifBlank { url.macName }, ltk, url.addresses, ch.remote)
                    settings = Settings()
                    queue.clear()
                    lastFeatureJson = null
                    _state.update { it.copy(settings = null, setupDone = false) }
                    ConnectionService.start(app)
                    refreshPresence(force = true) // new pairing, new UUID: the association is made in the setup steps
                } else if (macName.isNotBlank()) {
                    store.macName = macName
                }
                sessionReady(ctx)
            }

            override fun onRejected() {
                _state.update { it.copy(link = Link.Unpaired, code = null, message = "Scan the new code when ready") }
            }

            override fun onUnpaired() = forgetPairing("Your Mac unpaired this phone")

            override fun onMessage(m: Message) {
                try {
                    if (m.type == "xfer.cancel") macFiles.client.observe(m)
                    if (!engine.handle(m)) dispatch(m)
                } catch (e: Exception) {
                    android.util.Log.w(TAG, "message ${m.type} failed", e)
                    // never let one bad message kill the connection
                }
            }

            override fun onClosed(reason: String?) {
                android.util.Log.i(TAG, "session closed: $reason")
                engine.connectionLost()
                sessionEnded(ctx)
            }
        }
        val session = ClientSession(ch, deviceIdentity(), pairingInfo != null, listener) { Heartbeat.intervalMs(screenOn) }
        engine = TransferEngine({ session.send(it) }, FsLedger(macFiles.client, ledger), FsStore(macFiles.client, incoming))
        ctx = SessionCtx(session, engine)
        sess = ctx
        session.run()
    }

    private fun sessionReady(ctx: SessionCtx) {
        store.lastSeen = System.currentTimeMillis()
        presence.onTcp(true, store.lastSeen); scheduleParkCheck()
        notifs.resetSent()
        lastDevice = null
        _state.update { it.copy(link = Link.Connected, code = null, macName = store.macName, lastSeen = store.lastSeen, message = null) }
        registerBattery(ctx)
        sendDeviceStatus(force = true)
        lastFeatureJson = null
        applySettings()
        send(notifs.snapshot())
        flushOutbox()
        kickFileQueue()
        FindMyPhone.stop(app)
        macFiles.onConnected()
        mac.onConnected()
        refreshWalkAway()
    }

    private fun sessionEnded(ctx: SessionCtx) {
        ctx.batteryReceiver?.let { runCatching { app.unregisterReceiver(it) } }
        if (sess === ctx) sess = null
        presence.onTcp(false, System.currentTimeMillis()); scheduleParkCheck()
        media.setEnabled(false)
        callAudioWatcher.setWatching(false)
        requests.sms.setObserving(false)
        ClipAccessibilityService.setActive(false)
        macFiles.onDisconnected()
        mac.onDisconnected()
        auth.onDisconnected()
        refreshWalkAway()
        if (store.isPaired) {
            store.lastSeen = System.currentTimeMillis()
            _state.update { it.copy(link = if (it.link == Link.Unpaired) it.link else Link.Searching, lastSeen = store.lastSeen) }
        } else {
            _state.update { if (it.link == Link.Confirm || it.link == Link.Connecting) it.copy(link = Link.Unpaired, code = null, message = it.message ?: "That didn't work. Scan again.") else it }
        }
    }

    // ---------------------------------------------------------------- inbound messages

    private fun dispatch(m: Message) {
        when (m.type) {
            "settings" -> {
                val s = Settings(
                    m.bool("notifications") == true, m.bool("photos") == true, m.bool("calls") == true, m.bool("clipboard") == true,
                    mutedApps = m.arr("mutedApps")?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }?.toSet() ?: emptySet(),
                    screenshots = m.bool("screenshots") ?: true,
                    pauseBelowBattery = m.int("pauseBelowBattery")?.takeIf { it in 1..100 },
                    smsHistory = m.bool("smsHistory") == true,
                    media = m.bool("media") == true,
                    callAudio = m.bool("callAudio") == true,
                    walkAway = m.bool("walkAway") == true,
                )
                if (s.callAudio) store.callAudioEver = true
                settings = s; store.settings = s
                _state.update { it.copy(settings = s) }
                applySettings()
                if (s.notifications) send(notifs.snapshot())
            }
            "notif.reply" -> {
                val key = m.str("key") ?: return
                val err = notifs.reply(key, m.str("text") ?: "")
                send(Message.of("notif.result") { put("key", key); put("ok", err == null); if (err != null) put("error", err) })
            }
            "notif.action" -> {
                val key = m.str("key") ?: return
                val err = notifs.fireAction(key, m.int("index") ?: -1)
                send(Message.of("notif.result") { put("key", key); put("ok", err == null); if (err != null) put("error", err) })
            }
            "notif.open" -> m.str("key")?.let { notifs.open(it) }
            "notif.dismiss" -> m.str("key")?.let { notifs.dismiss(it) }
            "notif.read" -> m.str("key")?.let { notifs.markRead(it) }
            "call.action" -> callControl.perform(m.str("action") ?: "")
            "clip.set" -> if (settings.clipboard) m.str("text")?.let { Clipboard.write(app, it) }
            "fix.open" -> m.str("what")?.let { Fixer.post(app, it); watchFeaturesAfterFix() }
            "adb.verify" -> CallAudioSetup.writeVerify(app, m.str("nonce"))
            "link.open" -> LinkOpener.open(app, m.str("url"))
            "media.cmd" -> if (settings.media) media.command(m.str("action") ?: "", m.long("position"))
            "find.ring" -> FindMyPhone.start(app)
            "find.stop" -> FindMyPhone.stop(app)
            "remote.state", "mac.status", "mac.result", "mac.shortcuts", "mac.apps", "present.state", "mac.media" -> mac.onMessage(m)
            "auth.list.get", "auth.code.get", "auth.domain.set", "auth.import" -> auth.bridge.dispatch(m)
            else -> if (requests.handles(m.type)) requests.dispatch(m)
        }
    }

    // ---------------------------------------------------------------- features

    /** Debug builds only (DebugReceiver): apply settings in memory without persisting, to exercise features without the Mac. */
    fun debugApply(s: Settings) { settings = s; applySettings() }

    /** Re-read Android permissions (call on resume and after permission results) and apply. */
    fun refreshFeatures() {
        applySettings()
    }

    /**
     * The user usually fixes a setting from the Mac's prompt and never reopens Mydroid, so nothing would
     * re-check. Poll cheaply for two minutes after a fix.open so the Mac's warning clears within seconds.
     */
    private val fixWatch = java.util.concurrent.Executors.newSingleThreadScheduledExecutor { Thread(it, "mydroid-fixwatch").apply { isDaemon = true } }
    @Volatile private var fixWatchUntil = 0L
    fun watchFeaturesAfterFix() {
        val first = fixWatchUntil < System.currentTimeMillis()
        fixWatchUntil = System.currentTimeMillis() + 120_000
        if (!first) return
        fun tick() {
            runCatching { refreshFeatures() }
            if (System.currentTimeMillis() < fixWatchUntil) fixWatch.schedule({ tick() }, 2, java.util.concurrent.TimeUnit.SECONDS)
        }
        fixWatch.schedule({ tick() }, 2, java.util.concurrent.TimeUnit.SECONDS)
    }

    /** Ongoing-call notifications carry the caller's name for outgoing calls (see CallMonitor). */
    fun onCallNotification(sbn: android.service.notification.StatusBarNotification) = calls.onCallNotification(sbn)

    fun onListenerReady() {
        applySettings()
        if (isConnected) send(notifs.snapshot())
    }

    @Synchronized
    private fun applySettings() {
        val s = settings
        val r = Features.report(app, s, store.callAudioEver, store.instantCopy)
        _state.update { it.copy(report = r) }
        // Call audio (PROTOCOL.md 8.2.5): re-arm Wireless debugging when allowed, and follow the two settings while the Mac is here.
        CallAudioSetup.keepAlive(app, s)
        callAudioWatcher.setWatching(s.callAudio && isConnected && store.isPaired)
        if (s.photos && r.state(Feature.Photos) == FeatureState.On && store.isPaired) {
            photos.startObserving()
            if (!workerScheduled) { workerScheduled = true; PhotoCatchUpWorker.schedule(app) }
            if (isConnected) uploader.execute { photos.scan(); kickPhotoUpload() }
        } else {
            photos.stopObserving()
            PhotoCatchUpWorker.cancel(app); workerScheduled = false
        }
        if (s.calls && r.state(Feature.Calls) == FeatureState.On && store.isPaired) calls.start() else calls.stop()
        // The service only listens when the user opted in, the feature is on, the Mac is here and the service is enabled.
        ClipAccessibilityService.setActive(s.clipboard && isConnected && store.instantCopy && r.a11yEnabled)
        notifs.setMuted(s.mutedApps)
        requests.sms.setObserving(s.smsHistory && isConnected && store.isPaired && requests.sms.readable())
        media.setEnabled(s.media && isConnected && store.isPaired && r.state(Feature.Notifications) != FeatureState.NeedsPermission && Perms.hasNotificationAccess(app))
        sendFeatureStatus(r)
        refreshWalkAway()
    }

    private fun sendFeatureStatus(r: FeatureReport) {
        if (!isConnected) return
        val msg = Message.of("feature.status") {
            for (f in Feature.values()) put(f.wire, r.state(f).wire)
            put("clipboardMode", r.clipboardMode)
            put("otp", r.otp.wire)
            put("backgroundActivityRestricted", r.backgroundRestricted)
            put("callAudio", r.callAudio.state.wire)
            put("devOptions", r.callAudio.devOptions)
            put("adbWifi", r.callAudio.adbWifi)
        }
        val j = msg.header.toString()
        if (j == lastFeatureJson) return
        lastFeatureJson = j
        send(msg)
    }

    // ---------------------------------------------------------------- outbound


    fun send(m: Message): Boolean {
        val s = sess?.session ?: return false
        if (s.state != SessionState.READY) return false
        if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
            writer.execute { runCatching { s.send(m) }.onFailure { android.util.Log.w(TAG, "send ${m.type} failed", it) } }
            return true
        }
        return try {
            s.send(m); true
        } catch (e: IOException) {
            false
        }
    }

    fun kickPhotoUpload() {
        again.set(true)
        if (!uploading.compareAndSet(false, true)) return
        uploader.execute {
            try {
                while (again.getAndSet(false)) {
                    val s = sess ?: break
                    photos.drain(s.engine, transferLock, onSynced = { transfers.photoSynced() }) {
                        sess === s && s.session.state == SessionState.READY && settings.photos && !photosPaused() &&
                            Features.report(app, settings).state(Feature.Photos) == FeatureState.On
                    }
                }
            } catch (e: IOException) {
                // connection dropped; items stay queued and resume after reconnect
            } catch (e: Exception) {
                android.util.Log.w(TAG, "photo upload stopped", e)   // e.g. a revoked grant; never crash the service over one photo
            } finally {
                uploading.set(false)
                if (again.get() && isConnected) kickPhotoUpload()
            }
        }
    }

    // ---------------------------------------------------------------- sending files from the phone

    private val pickExec = Executors.newSingleThreadExecutor { Thread(it, "mydroid-pick").apply { isDaemon = true } }
    private val filesDraining = AtomicBoolean(false)
    private val filesAgain = AtomicBoolean(false)

    /**
     * Photos, videos and documents picked by the user (or shared into the app). They go into the durable outbox and out over the
     * transfer engine, one at a time, with live progress. When the Mac is away they simply wait. Returns the message to show.
     */
    /**
     * Queues files for the Mac. Each is copied into app storage first: read access from a share sheet or picker ends with
     * the screen that granted it, so [copied] runs (on the main thread) once the caller may let that screen close.
     */
    fun sendUris(uris: List<Uri>, copied: (() -> Unit)? = null): String {
        if (!store.isPaired) { copied?.invoke(); return "Pair with your Mac first" }
        if (uris.isEmpty()) { copied?.invoke(); return "" }
        start()
        pickExec.execute {
            try {
                transfers.pruneOutboxDir()
                for (u in uris) describe(u)?.let { f -> keepCopy(u, f)?.let { transfers.enqueue(it) } }
            } finally {
                copied?.let { mainHandler.post(it) }
            }
            kickFileQueue()
        }
        val n = uris.size
        if (isConnected) return if (n == 1) "Sending to ${store.macName}…" else "Sending $n files to ${store.macName}…"
        unpark("send to mac", force = true)
        return "Sends when your Mac is back"
    }

    /** A private copy of [uri] for the outbox, or null (and a failed entry in Activity) when it can't be read. */
    private fun keepCopy(uri: Uri, f: com.mydroid.android.transfers.OutboxFile): com.mydroid.android.transfers.OutboxFile? {
        val dir = transfers.outboxDir ?: return f
        val out = java.io.File(dir, f.id.replace(Regex("[^A-Za-z0-9]"), "_"))
        return try {
            dir.mkdirs()
            val n = app.contentResolver.openInputStream(uri)!!.use { ins -> out.outputStream().use { ins.copyTo(it) } }
            f.copy(uri = Uri.fromFile(out).toString(), size = n)
        } catch (e: Exception) {
            android.util.Log.w(TAG, "couldn't copy shared file", e)
            out.delete()
            val why = if (e is IOException && app.filesDir.usableSpace < f.size + 50_000_000) "Not enough space on your phone" else "Couldn't read it"
            transfers.recordFile(com.mydroid.android.transfers.Direction.ToMac, f.name, f.size, ok = false, error = why)
            null
        }
    }

    /** Name, size and type of a content URI, without reading its bytes. Null only if there is no usable name at all. */
    private fun describe(uri: Uri): com.mydroid.android.transfers.OutboxFile? {
        var name: String? = null
        var size = 0L
        try {
            app.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    name = c.getString(0)
                    size = if (c.isNull(1)) 0L else c.getLong(1)
                }
            }
        } catch (e: Exception) {
            // fall through with the fallback name
        }
        val n = (name ?: uri.lastPathSegment)?.substringAfterLast('/')?.takeIf { it.isNotBlank() } ?: "file"
        val mime = app.contentResolver.getType(uri)
            ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(n.substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"
        return com.mydroid.android.transfers.OutboxFile("file:${UUID.randomUUID()}", uri.toString(), n, mime, size, System.currentTimeMillis())
    }

    /** Sends whatever is in the file outbox while the Mac is reachable. Safe to call any time; a second call just asks for another pass. */
    fun kickFileQueue() {
        filesAgain.set(true)
        if (!filesDraining.compareAndSet(false, true)) return
        fileExec.execute {
            try {
                while (filesAgain.getAndSet(false)) {
                    while (true) {
                        val s = sess?.takeIf { it.session.state == SessionState.READY } ?: break
                        val f = transfers.nextQueued() ?: break
                        if (!sendQueuedFile(s, f)) break
                    }
                }
            } finally {
                filesDraining.set(false)
                if (filesAgain.get() && isConnected) kickFileQueue()
            }
        }
    }

    /** @return false when the link dropped and the file should stay queued. */
    private fun sendQueuedFile(s: SessionCtx, f: com.mydroid.android.transfers.OutboxFile): Boolean {
        val dirTo = com.mydroid.android.transfers.Direction.ToMac
        var tmp: java.io.File? = null
        fun failed(why: String): Boolean { transfers.dequeue(f.id); transfers.recordFile(dirTo, f.name, f.size, ok = false, error = why); return true }
        try {
            val uri = Uri.parse(f.uri)
            var src: FileSource = try { MediaStoreSource(app, uri, original = false) } catch (e: Exception) { return failed("Couldn't read it") }
            if (src.size <= 0) {
                // Some providers can't say how big a file is: take a private copy so the size and resume are exact.
                tmp = try {
                    java.io.File(app.cacheDir, "outgoing-" + f.id.replace(Regex("[^A-Za-z0-9]"), "_")).also { t ->
                        app.contentResolver.openInputStream(uri)!!.use { ins -> t.outputStream().use { ins.copyTo(it) } }
                    }
                } catch (e: Exception) { return failed("Couldn't read it") }
                src = FileFileSource(tmp)
            }
            val offer = Offer(f.id, "file", f.name, src.size, f.mime)
            transfers.liveStart(f.id, f.name, src.size)
            var last = 0L
            val hook = ChunkHook { _, offset ->
                val now = android.os.SystemClock.elapsedRealtime()
                if (now - last >= 100) { last = now; transfers.liveProgress(f.id, offset) }
            }
            val r = try {
                synchronized(transferLock) { s.engine.sendFile(offer, src, hook) }
            } catch (e: IOException) {
                // Link dropped: keep it queued and try again after reconnect. Still connected means the Mac just went quiet.
                return if (isConnected) failed("Your Mac didn't answer") else false
            } catch (e: Exception) {
                android.util.Log.w(TAG, "file send failed", e)
                return failed("Couldn't read it")
            }
            android.util.Log.i(TAG, "file sent result=$r size=${src.size}")
            when (r) {
                SendResult.DONE, SendResult.SKIPPED -> { transfers.dequeue(f.id); transfers.recordFile(dirTo, f.name, src.size) }
                SendResult.CANCELLED -> failed("Declined on your Mac")
                SendResult.FAILED -> failed("Your Mac couldn't save it")
            }
            return true
        } finally {
            transfers.liveEnd(f.id)
            tmp?.delete()
        }
    }

    /** From the in-app button or the tile activity; both are foreground so the clipboard read is allowed. */
    fun sendClipboardNow(ctx: Context): String {
        if (!store.isPaired) return "Pair with your Mac first"
        val text = Clipboard.readText(ctx) ?: return "Your clipboard is empty"
        if (!settings.clipboard) return "Clipboard sharing is off on your Mac"
        val msg = Clipboard.message(text) ?: return "Text is too long to send"
        return if (send(msg)) { Clipboard.markSynced(text); "Sent to ${store.macName}" } else "Your Mac isn't connected"
    }

    /** The "Instant copy (advanced)" toggle on Home. Saving the opt-in is all that arms the accessibility service. */
    fun setInstantCopy(on: Boolean) {
        store.instantCopy = on
        applySettings()
    }

    /**
     * Explicit user sends (the Send-to-Mac text box, "Paste", the text-selection menu): a single http/https/mailto URL becomes
     * `link.open`, anything else `clip.set`. Allowed even when the clipboard feature is off, because the user asked for it.
     * Returns the message to show. If the Mac isn't connected the text waits (one item, newest wins, memory only) and goes out on reconnect.
     */
    fun sendText(text: String, via: String): String {
        if (!store.isPaired) return "Pair with your Mac first"
        val url = com.mydroid.protocol.Links.safe(text)
        val msg = (if (url != null) Message.of("link.open") { put("url", url) } else Clipboard.message(text)) ?: return "Text is too long to send"
        start()
        val pt = PendingText(msg, System.currentTimeMillis(), url, text.length)
        if (send(msg)) {
            if (url == null) Clipboard.markSynced(text)
            android.util.Log.i(TAG, "${msg.type} sent via=$via len=${text.length}")
            recordText(pt)
            return "Sent to ${store.macName}"
        }
        synchronized(outboxLock) { outbox = pt }
        transfers.setPendingText(if (url != null) com.mydroid.android.transfers.Kind.Link else com.mydroid.android.transfers.Kind.Text, pt.label())
        unpark("send to mac", force = true)
        return "Sends when your Mac is back"
    }

    fun sendSelectedText(text: String): String = sendText(text, "process_text")

    /** "Paste" on Home: the clipboard is read now, while the app is in front. A copied URL opens on the Mac, text is copied, an image is sent as a file. */
    fun pasteFromClipboard(ctx: Context): String {
        if (!store.isPaired) return "Pair with your Mac first"
        return when (val r = Clipboard.read(ctx)) {
            Clipboard.Read.Empty -> "Your clipboard is empty"
            Clipboard.Read.Sensitive -> "Skipped: looks private"
            is Clipboard.Read.Text -> sendText(r.text, "paste")
            is Clipboard.Read.Content -> sendUris(listOf(r.uri))
        }
    }

    private class PendingText(val msg: Message, val at: Long, val url: String?, val chars: Int) {
        fun label(): String = if (url != null) host(url) else "Text"
        companion object {
            fun host(url: String): String = runCatching { java.net.URI(url).host }.getOrNull()?.removePrefix("www.")?.takeIf { it.isNotBlank() } ?: "Link"
        }
    }

    private fun recordText(p: PendingText) {
        transfers.record(com.mydroid.android.transfers.ActivityEntry(
            UUID.randomUUID().toString(), com.mydroid.android.transfers.Direction.ToMac,
            if (p.url != null) com.mydroid.android.transfers.Kind.Link else com.mydroid.android.transfers.Kind.Text,
            p.label(), if (p.url != null) null else "${p.chars} characters", System.currentTimeMillis(),
        ))
    }

    private val outboxLock = Any()
    private var outbox: PendingText? = null

    private fun flushOutbox() {
        val p = synchronized(outboxLock) { outbox.also { outbox = null } } ?: return
        transfers.clearPendingText()
        if (System.currentTimeMillis() - p.at > OUTBOX_TTL_MS) return
        if (send(p.msg)) {
            if (p.msg.type == "clip.set") p.msg.str("text")?.let { Clipboard.markSynced(it) }
            android.util.Log.i(TAG, "outbox sent type=${p.msg.type}")
            recordText(p)
        } else {
            synchronized(outboxLock) { if (outbox == null) outbox = p }
            transfers.setPendingText(if (p.url != null) com.mydroid.android.transfers.Kind.Link else com.mydroid.android.transfers.Kind.Text, p.label())
        }
    }

    /** From [ClipAccessibilityService] after it read the clipboard. Only the text itself decides whether it is sent. */
    fun onClipboardObserved(text: String, via: String) {
        if (!settings.clipboard || !isConnected) return
        if (Clipboard.alreadySynced(text)) {
            android.util.Log.i(TAG, "clip: unchanged or echo, not sent (len=${text.length})")
            return
        }
        val msg = Clipboard.message(text) ?: return
        if (send(msg)) {
            Clipboard.markSynced(text)
            android.util.Log.i(TAG, "clip.set sent via=$via len=${text.length}")
        }
    }

    fun markSetupDone() {
        store.setupDone = true
        _state.update { it.copy(setupDone = true) }
    }

    fun markOemOpened() {
        val now = System.currentTimeMillis()
        store.oemOpenedAt = now
        _state.update { it.copy(oemOpenedAt = now) }
    }

    fun consumeMessage() = _state.update { it.copy(message = null) }
    fun postMessage(text: String) = _state.update { it.copy(message = text) }
    fun postNotice(text: String) { if (text.isNotEmpty()) _state.update { it.copy(notice = text) } }
    fun consumeNotice() = _state.update { it.copy(notice = null) }

    // ---------------------------------------------------------------- device status

    private fun networkKind(): String {
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return "none"
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            else -> "none"
        }
    }

    private fun battery(): Pair<Int, Boolean>? {
        val b = app.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return null
        val level = b.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = b.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        val pct = if (level >= 0 && scale > 0) level * 100 / scale else 0
        val status = b.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        return pct to (status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL)
    }

    /** settings.pauseBelowBattery (PROTOCOL.md 7.2): photo sync waits while below the threshold and not charging. */
    private fun photosPaused(): Boolean {
        val below = settings.pauseBelowBattery ?: return false
        val (pct, charging) = battery() ?: return false
        return !charging && pct < below
    }

    private fun sendDeviceStatus(force: Boolean = false) {
        val (pct, charging) = battery() ?: return
        val net = networkKind()
        val lowPower = app.getSystemService(PowerManager::class.java).isPowerSaveMode
        val key = "$pct/$charging/$net/$lowPower"
        synchronized(this) {
            if (!force && key == lastDevice) return
            lastDevice = key
        }
        if (!force && settings.photos && !photosPaused()) kickPhotoUpload()
        val id = deviceIdentity()
        send(Message.of("device.status") {
            put("battery", pct); put("charging", charging); put("network", net); put("name", id.name); put("model", id.model); put("lowPowerMode", lowPower)
        })
    }

    private fun registerBattery(ctx: SessionCtx) {
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) = sendDeviceStatus()
        }
        ctx.batteryReceiver = r
        // Battery saver (PROTOCOL.md 7.9) rides along: same message, re-sent when it toggles.
        app.registerReceiver(r, IntentFilter(Intent.ACTION_BATTERY_CHANGED).apply { addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED) })
    }

    // ---------------------------------------------------------------- network changes

    private var lastNet: Network? = null
    private var sawFirstNetwork = false
    @Volatile private var pairingInFlight = false

    private fun registerNetworkCallback() {
        runCatching {
            cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    val prev = lastNet
                    lastNet = network
                    CallAudioSetup.keepAlive(app, settings) // Wi-Fi connect: Android may have switched Wireless debugging off
                    // Android reports the current network right after registering. That isn't a change.
                    if (!sawFirstNetwork) { sawFirstNetwork = true; return }
                    if (prev == network) return
                    networkChanged(closeSession = prev != null)
                }

                override fun onLost(network: Network) {
                    if (network == lastNet) {
                        lastNet = null
                        networkChanged(closeSession = true)
                    }
                }
            })
        }
    }

    /** The default network changed: restart the connection logic (it re-checks for Wi-Fi/ethernet itself). */
    private fun networkChanged(closeSession: Boolean) {
        backoffReset = true
        if (lanAvailable()) unpark("Wi-Fi network appeared")
        // A pairing attempt dials the QR addresses with its own timeout; don't abandon it.
        if (pairingInFlight) return
        racer?.cancel()
        if (closeSession) sess?.session?.close()
        poke()
        refreshStatusSoon()
    }

    // ---------------------------------------------------------------- screen state

    private fun registerScreenReceiver() {
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                when (i.action) {
                    // Broadcasts arrive on the main thread; heartbeatChanged(pingNow) writes to the socket.
                    Intent.ACTION_SCREEN_ON -> { screenOn = true; writer.execute { runCatching { sess?.session?.heartbeatChanged(pingNow = true) } }; wakeUp("screen on") }
                    Intent.ACTION_SCREEN_OFF -> { screenOn = false; writer.execute { runCatching { sess?.session?.heartbeatChanged() } } }
                    // Settings may have changed while the phone was in use elsewhere (e.g. battery, permissions).
                    Intent.ACTION_USER_PRESENT -> { auth.onUserPresent(); unpark("user unlocked"); wakeUp("user present"); writer.execute { runCatching { refreshFeatures() } } }
                }
            }
        }
        val f = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_SCREEN_OFF); addAction(Intent.ACTION_USER_PRESENT)
        }
        app.registerReceiver(r, f, Context.RECEIVER_NOT_EXPORTED)
    }

    private fun refreshStatusSoon() {
        mainHandler.postDelayed({ sendDeviceStatus() }, 500) // the sticky battery read + frame are tiny; no thread parked
    }
}

/** Tiny helper: collect a StateFlow on the current (background) thread. */
private fun <T> StateFlow<T>.collectBlocking(block: (T) -> Unit) {
    kotlinx.coroutines.runBlocking { collect { block(it) } }
}
