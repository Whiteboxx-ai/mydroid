import Foundation
import Network

public struct HubConfiguration {
    public var macName: String
    public var identity: Identity
    public var config: KeyValueStore
    public var ledgerURL: URL
    public var photosDirectory: URL
    public var downloadsDirectory: URL
    public var preferredPort: UInt16 = Server.defaultPort
    public var advertiseBonjour = true
    /// Where `photos.get` downloads (xid `lib:<id>`) go. Defaults to `Caches/Mydroid/Library`.
    public var libraryDirectory: URL

    public static var defaultLibraryDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mydroid/Library", isDirectory: true)
    }

    public init(macName: String, identity: Identity, config: KeyValueStore, ledgerURL: URL,
                photosDirectory: URL, downloadsDirectory: URL, preferredPort: UInt16 = Server.defaultPort,
                advertiseBonjour: Bool = true, libraryDirectory: URL? = nil) {
        self.macName = macName; self.identity = identity; self.config = config; self.ledgerURL = ledgerURL
        self.photosDirectory = photosDirectory; self.downloadsDirectory = downloadsDirectory
        self.preferredPort = preferredPort; self.advertiseBonjour = advertiseBonjour
        self.libraryDirectory = libraryDirectory ?? Self.defaultLibraryDirectory
    }
}

public enum HubEvent: @unchecked Sendable {
    case listening(port: UInt16)
    case confirmCode(code: String, phoneName: String)
    case paired(phoneId: String)
    case unpaired
    case sessionReady(reconnect: Bool)
    case sessionClosed
    /// Every inbound message after Hub's own handling (for tests and the smoke driver).
    case message(Message)
    case notificationPosted(PhoneNotification, isNew: Bool)
    case notificationRemoved(String)
    case notificationResult(key: String, ok: Bool, error: String?)
    case clipboard(String)
    case offer(xid: String, outcome: OfferOutcome)
    case received(SavedFile)
    case transferFailed(xid: String, error: String)
    case sent(xid: String, name: String, skipped: Bool)
    case sendFailed(xid: String, name: String, error: String)
    /// A `link.open` from the phone (already checked against `LinkPolicy`).
    case linkOpen(URL)
    // v1.3: SMS (7.5), photo library (7.7), calls history (7.8). Replies aren't correlated by id; see `RequestBook`.
    case smsThreads([SmsThread], request: SmsThreadsRequest?)
    case smsMessages(threadId: WireID, messages: [SmsMessage])
    case smsSent(SmsSent)
    case smsChanged(WireID)
    /// `sms.error`: `"permission"` or `"failed"`, and the request type it answers (`req`) when the phone says.
    case smsError(String, request: String?)
    case photosPage(PhotosPage)
    /// An empty `jpeg` means the phone couldn't make that thumbnail (`ok:false`).
    case photoThumb(id: WireID, jpeg: Data)
    /// `error` is `"permission"` when the phone can't read the call log (the list is then empty).
    case callsPage([CallRecord], error: String?)
    /// A `photos.get` download (xid `lib:<id>`) in progress, finished (the file is in the cache) or failed.
    case libraryProgress(id: String, done: Int64, total: Int64)
    case libraryReady(id: String, url: URL)
    case libraryFailed(id: String, error: String)
    // Quick Share receiving (see HubQuickShare.swift).
    /// A device other than the paired phone wants to send something. Answer with `Hub.quickShareRespond`.
    case quickShareRequest(QuickShareIncoming)
    /// The request above is no longer waiting (answered, timed out, or the sender gave up).
    case quickShareRequestEnded(id: String)
    /// Text that arrived by Quick Share. The app puts it on the clipboard.
    case quickShareText(String, from: String)
    /// A web link that arrived by Quick Share.
    case quickShareLink(URL, from: String)
    /// A Quick Share transfer finished and these files are saved (also reported one by one as `.received`).
    case quickShareDone(QuickShareDone)
    case quickShareFailed(from: String, reason: String)
    // v1.5 (PROTOCOL.md 10): the phone opened Remote and the Mac lacks Accessibility.
    case remoteAsk
}

/// Everything the Mac side knows and does, minus UI. Both the app and the test server drive this.
/// All state lives on `queue`; public methods are safe to call from any thread.
public final class Hub: ServerDelegate {
    public let queue = DispatchQueue(label: "com.mydroid.hub")
    public var onState: ((HubState) -> Void)?
    public var onEvent: ((HubEvent) -> Void)?
    public var log: (String) -> Void = { _ in } { didSet { server.log = log } }

    var cfg: HubConfiguration
    private let server: Server
    let ledger: TransferLedger
    var state = HubState()
    private var session: PairingSession?
    private var pairingWanted = false
    private var pairingGeneration = 0
    private var pending: Peer?
    var active: Peer?
    var receiver: TransferReceiver!
    var sender: TransferSender!
    var photosDirectory: URL
    var downloadsDirectory: URL
    var started = false
    private var screenshotsSubfolder = false
    private let libraryDirectory: URL
    private var smsThreadRequests = RequestBook<SmsThreadsRequest>()
    private var photoRequests = RequestBook<PhotosRequest>()
    // Quick Share receiving.
    let quickShare: QuickShareService
    var qsSettings = QuickShareSettings()
    var qsConfigured = false
    var qsPending: [String: (QSDecision) -> Void] = [:]
    var qsRequests: [String: QSRequest] = [:]
    var qsSaved: [String: [SavedFile]] = [:]
    var qsLastProgress: [String: Date] = [:]
    var fsPutDirectories: [String: URL] = [:]
    // Mac files on the phone (PROTOCOL.md section 9).
    private(set) var fileShare: FileShareService!
    // v1.5: Remote (10), quick actions (11).
    /// Every parsed `in.*` message, called on the Hub queue without any other work (no state publish, no main-thread hop).
    /// Whoever sets this should hand the input to another queue quickly.
    public var onRemoteInput: ((RemoteInput) -> Void)?
    /// Runs `mac.action` and `mac.shortcuts.get`. Without one the Hub answers "unsupported".
    public var macActions: MacActionPerforming?
    /// Apps, opening files, presenting and the Mac's own media (PROTOCOL.md 16). Without one the Hub answers "unsupported".
    public var macRemote: MacRemoteHandling?
    var presentWatching = false
    var mediaWatching = false
    var presentSent: PresentState?
    var mediaSent: MacMedia?
    var remoteSent: RemoteStatus?
    var macStatusSent: MacStatus?
    /// The app has told the Hub its Remote state. Until then (the headless test server never does) no `remote.state` goes out.
    var remoteReported = false
    /// Authenticator requests (PROTOCOL.md 14): `auth.code.get`, `auth.list.get`, `auth.domain.set`, and the phone's replies.
    public let auth = AuthBroker(transport: nil)

    public init(_ cfg: HubConfiguration) {
        self.cfg = cfg
        self.photosDirectory = cfg.photosDirectory
        self.downloadsDirectory = cfg.downloadsDirectory
        self.libraryDirectory = cfg.libraryDirectory
        ledger = TransferLedger(url: cfg.ledgerURL)
        quickShare = QuickShareService(deviceName: { [macName = cfg.macName] in macName }, advertise: cfg.advertiseBonjour)
        server = Server(macId: cfg.identity.macId, macName: cfg.macName, preferredPort: cfg.preferredPort,
                        advertise: cfg.advertiseBonjour, queue: queue)
        server.delegate = self
        auth.setTransport(self)
        installQuickShare()

        if let d = cfg.config.data(forKey: "settings"), let s = try? JSONDecoder().decode(SyncSettings.self, from: d) {
            state.settings = s
        }
        if cfg.identity.isPaired {
            state.bleUUID = cfg.identity.ltk.map(MydroidCrypto.bleUUID(ltk:))
            state.phoneBleUUID = cfg.identity.ltk.map(MydroidCrypto.phoneBleUUID(ltk:))
            state.link = .searching
            state.phone = PhoneInfo(name: cfg.identity.phoneName ?? "Your phone")
            state.lastSeen = (cfg.config.data(forKey: "lastSeen").flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(Double.init)).map(Date.init(timeIntervalSince1970:))
        }
        if let e = ledger.latest(kind: "photo"), FileManager.default.fileExists(atPath: e.path) {
            state.latestPhoto = Self.saved(e)
        }
        receiver = TransferReceiver(
            ledger: ledger,
            directoryFor: { [unowned self] kind, name, xid in
                if isLibraryTransfer(xid) { return self.libraryDirectory.appendingPathComponent(Self.safeComponent(String(xid.dropFirst(4))), isDirectory: true) }
                if isFileSharePut(xid), let dir = self.fsPutDirectories[xid] { return dir }
                guard kind == "photo" else { return self.downloadsDirectory }
                if self.screenshotsSubfolder, Screenshots.isScreenshot(name: name) {
                    return self.photosDirectory.appendingPathComponent("Screenshots", isDirectory: true)
                }
                return self.photosDirectory
            },
            send: { [unowned self] m in self.active?.send(m) },
            emit: { [unowned self] e in self.receiverEvent(e) },
            stagingDir: cfg.ledgerURL.deletingLastPathComponent().appendingPathComponent("Incoming", isDirectory: true))
        sender = TransferSender(
            queue: queue,
            send: { [unowned self] m, done in
                if let a = self.active { a.send(m, completion: done) } else { done(false) }
            },
            emit: { [unowned self] e in self.senderEvent(e) })
        fileShare = FileShareService(
            queue: queue, macName: cfg.macName,
            send: { [unowned self] m in self.active?.send(m) },
            offer: { [unowned self] url, xid in self.sender.offer(file: url, xid: xid) != nil },
            log: { [unowned self] m in self.log(m) })
    }

    /// An id from the phone, made safe to use as one path component.
    public static func safeComponent(_ s: String) -> String {
        let t = s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        return t.isEmpty ? "_" : t
    }

    private static func saved(_ e: LedgerEntry) -> SavedFile {
        SavedFile(xid: e.xid, kind: e.kind, url: URL(fileURLWithPath: e.path), name: e.name, size: e.size, taken: e.taken, savedAt: e.savedAt)
    }

    // MARK: Lifecycle

    public func start() {
        queue.async {
            self.started = true
            self.server.start()
            self.reconcileQuickShare()
        }
    }

    /// Starts and waits until the listener is ready. Returns the port.
    public func startAndWait(timeout: TimeInterval = 5) -> UInt16? {
        start()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let p = queue.sync(execute: { server.port }) { return p }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    public func restartListener(dropConnections: Bool) {
        queue.async {
            guard self.started else { return }
            self.server.restart(dropConnections: dropConnections)
            self.quickShare.restart(dropConnections: dropConnections)
            self.reconcileQuickShare()          // starts it if the listener had failed (no network)
            self.refreshPairingURL()
        }
    }

    /// Say goodbye to the phone and stop. Blocks briefly so `bye` gets out.
    public func stop() {
        let sem = DispatchSemaphore(value: 0)
        queue.async {
            self.started = false
            self.quickShare.stop()
            if let a = self.active {
                a.send(Message("bye")) { _ in
                    self.queue.async { self.server.shutdown(); sem.signal() }
                }
            } else {
                self.server.shutdown(); sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + 0.6)
    }

    public var snapshot: HubState { queue.sync { state } }
    public var listeningPort: UInt16? { queue.sync { server.port } }
    public var pairURL: String? { queue.sync { state.pairing?.url } }
    public var macId: String { cfg.identity.macId }

    func publish() {
        let s = state
        onState?(s)
    }

    func emit(_ e: HubEvent) { onEvent?(e) }

    // MARK: Settings

    public func setSettings(_ s: SyncSettings) {
        queue.async {
            self.state.settings = s
            // Muted apps vanish from the list right away.
            let muted = Set(s.mutedApps)
            if !muted.isEmpty {
                let kept = self.state.notifications.items.filter { !muted.contains($0.pkg) }
                if kept.count != self.state.notifications.items.count { self.state.notifications.replace(with: kept) }
            }
            if let d = try? JSONEncoder().encode(s) { self.cfg.config.set(d, forKey: "settings") }
            self.sendSettings()
            self.publish()
        }
    }

    public func setPhotosDirectory(_ url: URL) { queue.async { self.photosDirectory = url } }
    public func setScreenshotsSubfolder(_ on: Bool) { queue.async { self.screenshotsSubfolder = on } }

    private func sendSettings() {
        active?.send(Message("settings", state.settings.wireFields))
    }

    // MARK: Pairing

    /// Shows a fresh QR (new secret). Expires after 10 minutes (and renews itself while wanted).
    public func startPairing() {
        queue.async {
            self.pairingWanted = true
            self.newPairingSession()
        }
    }

    public func cancelPairing() {
        queue.async {
            self.pairingWanted = false
            self.session = nil
            self.pairingGeneration += 1
            if let p = self.pending { self.pending = nil; p.close() }
            self.state.pairing = nil
            self.publish()
        }
    }

    private func newPairingSession() {
        session = PairingSession()
        pairingGeneration += 1
        let gen = pairingGeneration
        queue.asyncAfter(deadline: .now() + PairingSession.lifetime) { [weak self] in
            guard let self, self.pairingGeneration == gen, self.pairingWanted else { return }
            if let p = self.pending { self.pending = nil; p.close() }
            self.newPairingSession()
        }
        refreshPairingURL()
    }

    private func refreshPairingURL() {
        guard let session, pairingWanted else { return }
        guard let port = server.port else { publish(); return }
        let url = session.url(macId: cfg.identity.macId, macName: cfg.macName, addresses: NetworkInfo.addresses(port: port))
        state.pairing = PairingInfo(url: url, expires: session.expires,
                                    confirmCode: state.pairing?.confirmCode, phoneName: state.pairing?.phoneName)
        publish()
    }

    /// The user clicked "Codes match".
    public func confirmPairing() {
        queue.async {
            guard let p = self.pending, p.isReady else { return }
            self.pending = nil
            p.send(Message("pair.confirmed"))
            if let old = self.active, old !== p {
                if old.phoneId != p.phoneId { old.send(Message("unpair")) }
                self.active = nil
                old.close()
            }
            self.cfg.identity.savePairing(phoneId: p.phoneId, ltk: p.ltk, phoneName: p.phoneName)
            self.pairingWanted = false
            self.session = nil
            self.pairingGeneration += 1
            self.state.pairing = nil
            self.state.phone = PhoneInfo(name: p.phoneName)
            self.state.bleUUID = MydroidCrypto.bleUUID(ltk: p.ltk)
            self.state.phoneBleUUID = MydroidCrypto.phoneBleUUID(ltk: p.ltk)
            self.emit(.paired(phoneId: p.phoneId))
            self.activate(p, reconnect: false)
        }
    }

    /// The user clicked "Scan again".
    public func rejectPairing() {
        queue.async {
            if let p = self.pending {
                self.pending = nil
                p.send(Message("pair.rejected")) { _ in self.queue.async { p.close() } }
            }
            self.state.pairing?.confirmCode = nil
            self.state.pairing?.phoneName = nil
            if self.pairingWanted { self.newPairingSession() } else { self.publish() }
        }
    }

    public func unpair() {
        queue.async { self.forgetPhone(notifyPhone: true) }
    }

    private func forgetPhone(notifyPhone: Bool) {
        if let a = active {
            active = nil
            if notifyPhone { a.send(Message("unpair")) { _ in self.queue.async { a.close() } } } else { a.close() }
        }
        cfg.identity.clearPairing()
        cfg.config.set(nil, forKey: "lastSeen")
        let settings = state.settings
        let remote = state.remote, macStatus = state.macStatus
        state = HubState()
        state.settings = settings
        state.remote = remote
        state.macStatus = macStatus
        remoteSent = nil; macStatusSent = nil
        state.port = server.port
        if let e = ledger.latest(kind: "photo"), FileManager.default.fileExists(atPath: e.path) { state.latestPhoto = Self.saved(e) }
        emit(.unpaired)
        reconcileQuickShare()
        publish()
    }

    // MARK: ServerDelegate

    public func server(_ server: Server, ltkFor hello: HelloRequest) -> Data? {
        if hello.pairing {
            guard pairingWanted, let s = session, !s.isExpired else { return nil }
            if let old = pending { pending = nil; old.close() }
            return s.ltk
        }
        guard cfg.identity.phoneId == hello.phoneId else { return nil }
        return cfg.identity.ltk
    }

    public func server(_ server: Server, peerAuthenticated peer: Peer, auth: Message) {
        if peer.isPairing {
            pending = peer
            state.pairing?.confirmCode = peer.confirmCode
            state.pairing?.phoneName = peer.phoneName
            emit(.confirmCode(code: peer.confirmCode, phoneName: peer.phoneName))
            publish()
        } else {
            if let old = active, old !== peer { old.close() }
            if state.phone == nil { state.phone = PhoneInfo(name: peer.phoneName) }
            let model = auth.string("model") ?? ""
            state.phone?.name = peer.phoneName
            if !model.isEmpty { state.phone?.model = model }
            cfg.identity.updatePhoneName(peer.phoneName)
            activate(peer, reconnect: true)
        }
    }

    private func activate(_ peer: Peer, reconnect: Bool) {
        active = peer
        state.link = .connected
        state.listenerError = nil
        state.lastSeen = Date()
        state.phoneHost = peer.remoteIPv4
        sendSettings()
        auth.setConnected(true)
        remoteSent = nil; macStatusSent = nil
        sendRemoteState()
        sendMacStatus()
        emit(.sessionReady(reconnect: reconnect))
        reconcileQuickShare()
        publish()
    }

    public func server(_ server: Server, peerClosed peer: Peer) {
        if peer === pending {
            pending = nil
            state.pairing?.confirmCode = nil
            state.pairing?.phoneName = nil
            publish()
        }
        guard peer === active else { return }
        active = nil
        auth.setConnected(false)
        receiver.connectionClosed()
        sender.connectionClosed()
        state.transfers.removeAll()
        if cfg.identity.isPaired { state.link = .searching }
        state.lastSeen = Date()
        cfg.config.set(Data(String(Date().timeIntervalSince1970).utf8), forKey: "lastSeen")
        state.call = nil
        state.features = FeatureStatus()
        state.media = nil
        state.phoneHost = nil
        smsThreadRequests.removeAll()
        photoRequests.removeAll()
        remoteSent = nil; macStatusSent = nil
        stopRemoteV2Watching()
        fileShare.connectionClosed()
        fsPutDirectories.removeAll()
        emit(.sessionClosed)
        reconcileQuickShare()
        publish()
    }

    public func server(_ server: Server, listenerChanged port: UInt16?, error: String?) {
        state.port = port
        state.listenerError = error
        if let port { emit(.listening(port: port)) }
        refreshPairingURL()
        publish()
    }

    public func server(_ server: Server, peer: Peer, received m: Message) {
        if peer === pending {
            switch m.type {
            case "ping": peer.send(Message("pong"))
            case "bye": peer.close()
            default: break
            }
            return
        }
        guard peer === active else { return }
        // Pointer, scroll and key input is the hot path: straight to the handler, nothing published, nothing sent to the main thread.
        if RemoteInput.isInput(m.type) {
            if let input = RemoteInput(message: m) { onRemoteInput?(input) }
            return
        }
        dispatch(m, from: peer)
        emit(.message(m))
        publish()
    }

    // MARK: Inbound dispatch

    private func dispatch(_ m: Message, from peer: Peer) {
        switch m.type {
        case "ping": peer.send(Message("pong"))
        case "pong": break
        case "bye": peer.close()
        case "unpair": forgetPhone(notifyPhone: false)
        case "device.status":
            var info = state.phone ?? PhoneInfo(name: peer.phoneName)
            if let n = m.string("name"), !n.isEmpty { info.name = n }
            if let md = m.string("model") { info.model = md }
            if let b = m.int("battery") { info.battery = Int(b) }
            info.charging = m.bool("charging") ?? info.charging
            info.network = m.string("network").flatMap(NetworkKind.init(rawValue:)) ?? info.network
            info.lowPowerMode = m.bool("lowPowerMode") ?? info.lowPowerMode
            state.phone = info
        case "feature.status":
            var f = state.features
            func st(_ k: String) -> FeatureState { m.string(k).flatMap(FeatureState.init(rawValue:)) ?? .unknown }
            f.notifications = st("notifications"); f.photos = st("photos"); f.calls = st("calls"); f.clipboard = st("clipboard")
            // Older phones send "backgroundRestricted" when the app is subject to standard battery optimization.
            f.backgroundRestricted = m.bool("backgroundActivityRestricted") ?? false
            state.features = f
        case "notif.posted":
            if let n = PhoneNotification(fields: m.fields), !state.settings.mutedApps.contains(n.pkg) {
                let isNew = state.notifications.post(n)
                emit(.notificationPosted(n, isNew: isNew))
            }
        case "notif.removed":
            if let k = m.string("key") { state.notifications.remove(k); emit(.notificationRemoved(k)) }
        case "notif.snapshot":
            let list = (m.array("items") ?? []).compactMap(PhoneNotification.init(fields:))
                .filter { !state.settings.mutedApps.contains($0.pkg) }
            state.notifications.replace(with: list)
        case "notif.result":
            if let k = m.string("key") { emit(.notificationResult(key: k, ok: m.bool("ok") ?? false, error: m.string("error"))) }
        case "call.state":
            guard let id = m.string("callId"), let ph = m.string("state").flatMap(CallPhase.init(rawValue:)) else { break }
            var c = state.call?.callId == id ? state.call! :
                CallInfo(callId: id, phase: ph, incoming: m.bool("incoming") ?? true, number: nil, name: nil, startedAt: Date())
            c.phase = ph
            c.incoming = m.bool("incoming") ?? c.incoming
            c.number = m.string("number") ?? c.number
            c.name = m.string("name") ?? c.name
            if ph == .active, state.call?.phase != .active { c.startedAt = Date() }
            state.call = c
        case "clip.set":
            if state.settings.clipboard, let t = m.string("text") { emit(.clipboard(t)) }
        case "media.state":
            if var next = MediaState(message: m) {
                if next.art == nil, let old = state.media, old.sameTrack(as: next) { next.art = old.art }
                // Like the art, `mediaId` is only sent when the track changes (PROTOCOL.md 15).
                if next.mediaId == nil, let old = state.media, old.sameTrack(as: next) { next.mediaId = old.mediaId }
                state.media = next
            } else {
                state.media = nil
            }
        case "link.open":
            if let u = m.string("url").flatMap(LinkPolicy.parse) { emit(.linkOpen(u)) }
        case "sms.threads":
            emit(.smsThreads(SmsDecode.threads(m), request: smsThreadRequests.pop()))
        case "sms.messages":
            if let r = SmsDecode.messages(m) { emit(.smsMessages(threadId: r.threadId, messages: r.messages)) }
        case "sms.sent":
            if let r = SmsDecode.sent(m) { emit(.smsSent(r)) }
        case "sms.changed":
            if let t = SmsDecode.changed(m) { emit(.smsChanged(t)) }
        case "sms.error":
            emit(.smsError(m.string("error") ?? "failed", request: m.string("req")))
        case "photos.page":
            if let p = PhotosDecode.page(m, request: photoRequests.pop()) { emit(.photosPage(p)) }
        case "photos.thumb":
            if let id = WireID(any: m.fields["id"]) { emit(.photoThumb(id: id, jpeg: m.bool("ok") == false ? Data() : m.payload)) }
        case "calls.page":
            emit(.callsPage(CallRecord.page(m), error: m.string("error")))
        case "xfer.offer" where isFileSharePut(m.string("xid") ?? ""):
            acceptFileSharePut(m)
        case "xfer.offer", "xfer.chunk", "xfer.end":
            receiver.handle(m)
        case "xfer.cancel":
            // The phone refusing a `photos.get` (no access, file gone) is a cancel for an offer that never came.
            if let x = m.string("xid"), isLibraryTransfer(x), !receiver.isReceiving(x) {
                emit(.libraryFailed(id: String(x.dropFirst(4)), error: "Your phone couldn't send that photo"))
            }
            receiver.handle(m); sender.handle(m)
        case "xfer.accept", "xfer.skip", "xfer.done":
            sender.handle(m)
        case "remote.ask": emit(.remoteAsk)
        case "auth.code", "auth.list", "auth.import.result": auth.handle(m)
        case "mac.action": handleMacAction(m, from: peer)
        case "mac.shortcuts.get": handleShortcutsGet(m, from: peer)
        case "mac.apps.get", "mac.launch", "mac.open", "present.start", "present.watch", "mac.media.watch", "mac.media.cmd":
            handleRemoteV2(m, from: peer)
        case _ where FileShareService.handles(m.type):
            fileShare.handle(m)
        default:
            log("ignoring unknown message type \(m.type)")
        }
    }

    private func receiverEvent(_ e: ReceiverEvent) {
        switch e {
        case let .offer(xid, _, _, _, outcome): emit(.offer(xid: xid, outcome: outcome))
        case let .progress(xid, _, _, written, size) where isLibraryTransfer(xid):
            emit(.libraryProgress(id: String(xid.dropFirst(4)), done: written, total: size))
        case let .progress(xid, name, kind, written, size):
            let p = TransferProgress(xid: xid, name: name, kind: kind, outgoing: false, done: written, total: size)
            if let i = state.transfers.firstIndex(where: { $0.xid == xid }) { state.transfers[i] = p } else { state.transfers.append(p) }
            publish()
        case let .received(f) where isLibraryTransfer(f.xid):
            emit(.libraryReady(id: String(f.xid.dropFirst(4)), url: f.url))
        case let .received(f):
            state.transfers.removeAll { $0.xid == f.xid }
            if f.kind == "photo" { state.latestPhoto = f }
            emit(.received(f))
            publish()
        case let .failed(xid, error) where isLibraryTransfer(xid):
            emit(.libraryFailed(id: String(xid.dropFirst(4)), error: error))
        case let .failed(xid, error):
            state.transfers.removeAll { $0.xid == xid }
            emit(.transferFailed(xid: xid, error: error))
            publish()
        }
    }

    private func senderEvent(_ e: SenderEvent) {
        switch e {
        case let .progress(p):
            if let i = state.transfers.firstIndex(where: { $0.xid == p.xid }) { state.transfers[i] = p } else { state.transfers.append(p) }
        case let .finished(xid, name, skipped):
            state.transfers.removeAll { $0.xid == xid }
            // The phone pulling a shared file isn't something the user sent: no "Sent" entry or toast.
            if !isFileShareGet(xid) { emit(.sent(xid: xid, name: name, skipped: skipped)) }
        case let .failed(xid, name, error):
            state.transfers.removeAll { $0.xid == xid }
            if !isFileShareGet(xid) { emit(.sendFailed(xid: xid, name: name, error: error)) }
        }
        publish()
    }

    // MARK: Outbound actions

    func send(_ m: Message) { active?.send(m) }

    public func reply(key: String, text: String) { queue.async { self.send(Message("notif.reply", ["key": key, "text": text])) } }
    public func dismiss(key: String) {
        queue.async {
            self.send(Message("notif.dismiss", ["key": key]))
            self.state.notifications.remove(key)
            self.publish()
        }
    }
    /// Open on phone (PROTOCOL.md 13.2): the phone fires the notification's own tap action and answers `notif.result`.
    public func openOnPhone(key: String) { queue.async { self.send(Message("notif.open", ["key": key])) } }
    public func performAction(key: String, index: Int) { queue.async { self.send(Message("notif.action", ["key": key, "index": index])) } }
    public func callAction(_ action: String) {
        queue.async {
            guard let c = self.state.call else { return }
            self.send(Message("call.action", ["callId": c.callId, "action": action]))
            if action == "mute" || action == "unmute" { self.state.call?.muted = (action == "mute"); self.publish() }
        }
    }
    public func clearCall() { queue.async { self.state.call = nil; self.publish() } }
    public func findPhone() { queue.async { self.send(Message("find.ring")) } }
    public func stopFindingPhone() { queue.async { self.send(Message("find.stop")) } }
    public func fix(_ what: FixKind) { queue.async { self.send(Message("fix.open", ["what": what.rawValue])) } }
    public func sendPing() { queue.async { self.send(Message("ping")) } }

    /// Call audio setup (PROTOCOL.md 8.2.4): the phone writes `nonce` to its verify file, and the Mac reads it back over adb.
    public func sendAdbVerify(nonce: String) { queue.async { self.send(Message("adb.verify", ["nonce": nonce])) } }

    // MARK: v1.3 requests (SMS 7.5, read sync 7.6, photo library 7.7, calls 7.8)

    /// Read sync: the phone fires the notification's mark-as-read action, or cancels it.
    public func markRead(key: String) { queue.async { self.send(Message("notif.read", ["key": key])) } }

    public func requestSmsThreads(limit: Int = 50, before: Date? = nil) {
        queue.async {
            guard self.active != nil else { return }
            self.smsThreadRequests.push(SmsThreadsRequest(limit: limit, before: before))
            var f: [String: Any] = ["limit": limit]
            if let before { f["before"] = millis(before) }
            self.send(Message("sms.threads.get", f))
        }
    }

    public func requestSmsMessages(threadId: WireID, limit: Int = 50, before: Date? = nil) {
        queue.async {
            var f: [String: Any] = ["threadId": threadId.json, "limit": limit]
            if let before { f["before"] = millis(before) }
            self.send(Message("sms.messages.get", f))
        }
    }

    /// Sends a text through the phone. The answer is `.smsSent` with the same `clientId`.
    @discardableResult
    public func sendSms(to: [String], text: String, threadId: WireID? = nil, clientId: String = UUID().uuidString.lowercased()) -> String {
        queue.async {
            var f: [String: Any] = ["clientId": clientId, "to": to, "text": text]
            if let threadId { f["threadId"] = threadId.json }
            self.send(Message("sms.send", f))
        }
        return clientId
    }

    public func requestPhotos(limit: Int = 60, before: Date? = nil, album: PhotoAlbum = .all) {
        queue.async {
            guard self.active != nil else { return }
            self.photoRequests.push(PhotosRequest(album: album, before: before))
            var f: [String: Any] = ["limit": limit, "album": album.rawValue]
            if let before { f["before"] = millis(before) }
            self.send(Message("photos.list", f))
        }
    }

    /// Thumbnails come back one `.photoThumb` per id. Batches of up to 30.
    public func requestThumbs(ids: [WireID]) {
        queue.async {
            for start in stride(from: 0, to: ids.count, by: 30) {
                let batch = ids[start..<min(start + 30, ids.count)]
                self.send(Message("photos.thumbs.get", ["ids": batch.map(\.json)]))
            }
        }
    }

    /// Downloads the original into the cache. Progress and the result arrive as `.libraryProgress` and `.libraryReady`.
    public func downloadPhoto(id: WireID) { queue.async { self.send(Message("photos.get", ["id": id.json])) } }

    /// Where `downloadPhoto` puts a file once it has arrived.
    public func libraryFile(id: WireID, name: String) -> URL {
        libraryDirectory.appendingPathComponent(Self.safeComponent(id.text), isDirectory: true)
            .appendingPathComponent(FileNaming.sanitize(name))
    }

    public func requestCalls(limit: Int = 100) { queue.async { self.send(Message("calls.list", ["limit": limit])) } }

    /// Asks the phone to place a call. The audio stays on the phone.
    public func dial(number: String) { queue.async { self.send(Message("call.dial", ["number": number])) } }

    /// Newest first. Photos synced automatically and files received, from the dedupe ledger (never library downloads).
    public func recentTransfers(limit: Int = 300) -> [SavedFile] {
        queue.sync { ledger.recent(limit: limit).map(Self.saved) }
    }

    /// A photo already saved by auto-sync with this name and size.
    public func syncedPhoto(name: String, size: Int64) -> SavedFile? {
        queue.sync {
            ledger.recent(limit: 5000).first { $0.kind == "photo" && $0.name == name && $0.size == size
                && FileManager.default.fileExists(atPath: $0.path) }.map(Self.saved)
        }
    }

    /// Sends text to the phone's clipboard. Only when the feature is on and a phone is connected.
    public func sendClipboard(_ text: String) {
        queue.async {
            guard self.state.settings.clipboard, self.state.link == .connected else { return }
            self.send(Message("clip.set", ["text": text]))
        }
    }

    /// Explicit "send to phone" text. Goes through even when clipboard sync is off, because the user asked.
    @discardableResult
    public func sendText(_ text: String) -> Bool {
        queue.sync {
            guard active != nil, !text.isEmpty, text.utf8.count <= 1 << 20 else { return false }
            send(Message("clip.set", ["text": text]))
            return true
        }
    }

    /// Opens a link on the phone (`link.open`). Only http, https and mailto.
    @discardableResult
    public func sendLink(_ url: URL) -> Bool {
        queue.sync {
            guard active != nil, LinkPolicy.allowed(url) else { return false }
            send(Message("link.open", ["url": url.absoluteString]))
            return true
        }
    }

    /// `action`: play, pause, toggle, next, prev or seek (with `position` in ms).
    public func mediaCommand(_ action: String, position: Int64? = nil) {
        queue.async {
            var f: [String: Any] = ["action": action]
            if let position { f["position"] = position }
            self.send(Message("media.cmd", f))
        }
    }

    @discardableResult
    public func sendFile(_ url: URL) -> Bool { offerFile(url) != nil }

    /// Like `sendFile`, and returns the transfer id so the caller can follow it (`.sent`, `.sendFailed`).
    public func offerFile(_ url: URL) -> String? {
        queue.sync {
            guard active != nil else { return nil }
            return sender.offer(file: url)
        }
    }

    /// Smoke-test variant with a known xid.
    public func sendFile(_ url: URL, xid: String) {
        queue.async { _ = self.sender.offer(file: url, xid: xid) }
    }
}

extension Hub: AuthTransport {
    public func sendAuth(_ m: Message) { queue.async { self.send(m) } }
}
