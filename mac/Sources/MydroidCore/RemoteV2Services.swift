import Foundation

// The services behind PROTOCOL.md section 16. Pure logic over the seams in RemoteV2.swift.

// MARK: - Presenting

public enum PresenterApp: CaseIterable, Sendable {
    case keynote, powerPoint, preview

    public var bundleId: String {
        switch self {
        case .keynote: return "com.apple.iWork.Keynote"
        case .powerPoint: return "com.microsoft.Powerpoint"
        case .preview: return "com.apple.Preview"
        }
    }
    public var name: String {
        switch self {
        case .keynote: return "Keynote"
        case .powerPoint: return "PowerPoint"
        case .preview: return "Preview"
        }
    }

    public static func from(bundleId: String?) -> PresenterApp? { allCases.first { $0.bundleId == bundleId } }

    /// `with timeout` keeps a hung app from holding the script (and the poll) for two minutes.
    var stateScript: String? {
        switch self {
        case .keynote:
            return """
            with timeout of 3 seconds
            tell application "Keynote"
              if not playing then return {"stopped"}
              set d to front document
              set s to current slide of d
              set n to slide number of s
              set c to count of slides of d
              set t to ""
              try
                set t to presenter notes of s
              end try
              set ttl to ""
              try
                set ttl to object text of default title item of s
              end try
              return {"playing", (n as text), (c as text), t, ttl}
            end tell
            end timeout
            """
        case .powerPoint:
            return """
            with timeout of 3 seconds
            tell application "Microsoft PowerPoint"
              if (count of slide show windows) is 0 then return {"stopped"}
              set v to slide show view of slide show window 1
              set i to current show position of v
              set c to count of slides of active presentation
              return {"playing", (i as text), (c as text), "", ""}
            end tell
            end timeout
            """
        case .preview: return nil
        }
    }

    var startScript: String? {
        switch self {
        case .keynote: return "with timeout of 5 seconds\ntell application \"Keynote\"\nactivate\nstart front document\nend tell\nend timeout"
        case .powerPoint, .preview: return nil
        }
    }

    /// What to press when the app can't be scripted: Keynote ⌥⌘P, PowerPoint ⇧⌘Return, Preview ⇧⌘F.
    var startKeys: (code: UInt16, flags: ModifierFlags) {
        switch self {
        case .keynote: return (0x23, [.option, .command])
        case .powerPoint: return (0x24, [.shift, .command])
        case .preview: return (0x03, [.shift, .command])
        }
    }
}

public final class PresentService {
    private let workspace: AppWorkspace
    private let scripts: ScriptRunning
    private let poster: SyntheticEventPoster
    private let queue: DispatchQueue
    private let publish: @Sendable (PresentState) -> Void
    private let after: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private let pollInterval: TimeInterval

    private var watching = false
    private var polling = false
    private var timer: DispatchSourceTimer?
    private var lastPublished: PresentState?

    public init(workspace: AppWorkspace, scripts: ScriptRunning, poster: SyntheticEventPoster, queue: DispatchQueue = DispatchQueue(label: "mydroid.present"),
                pollInterval: TimeInterval = 1.0,
                after: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { d, work in DispatchQueue.global().asyncAfter(deadline: .now() + d, execute: work) },
                publish: @escaping @Sendable (PresentState) -> Void) {
        self.workspace = workspace; self.scripts = scripts; self.poster = poster; self.queue = queue
        self.pollInterval = pollInterval; self.after = after; self.publish = publish
    }

    // MARK: Starting

    /// Opens the deck and, with `play`, waits for its app to come forward and starts the slideshow.
    public func start(_ url: URL, play: Bool, completion: @escaping @Sendable (MacActionResult) -> Void) {
        let app = PresenterApp.from(bundleId: workspace.defaultAppId(for: url))
        workspace.open(url) { [weak self] opened in
            guard let self else { return }
            guard opened.ok else { return completion(opened) }
            guard play, let app else { return completion(.success) }
            self.waitForFront(app, deadline: Date().addingTimeInterval(10)) { shown in
                guard shown else { return completion(.failure("The deck didn't open in time")) }
                self.begin(app, completion: completion)
            }
        }
    }

    private func waitForFront(_ app: PresenterApp, deadline: Date, completion: @escaping @Sendable (Bool) -> Void) {
        if workspace.frontmostBundleId() == app.bundleId {
            // The window needs a moment after the app comes forward before it can play.
            return after(1.5) { completion(true) }
        }
        guard Date() < deadline else { return completion(false) }
        after(0.4) { [weak self] in self?.waitForFront(app, deadline: deadline, completion: completion) }
    }

    private func begin(_ app: PresenterApp, completion: @escaping @Sendable (MacActionResult) -> Void) {
        guard let script = app.startScript else { return pressStartKeys(app, completion: completion) }
        scripts.run(script) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .ok: completion(.success)
            case .denied, .failed: self.pressStartKeys(app, completion: completion)
            }
        }
    }

    private func pressStartKeys(_ app: PresenterApp, completion: @escaping @Sendable (MacActionResult) -> Void) {
        let k = app.startKeys
        poster.post(.key(code: k.code, down: true, flags: k.flags))
        poster.post(.key(code: k.code, down: false, flags: k.flags))
        completion(.success)
    }

    // MARK: Watching

    public func setWatching(_ on: Bool) {
        queue.async {
            guard on != self.watching else { return }
            self.watching = on
            self.lastPublished = nil
            if on { self.startTimer(); self.tick() } else { self.timer?.cancel(); self.timer = nil }
        }
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// One look at the presenter apps. Skipped while the last one is still running, so a slow app can't pile up scripts.
    func tick() {
        guard watching, !polling else { return }
        guard let app = PresenterApp.allCases.first(where: { $0 != .preview && workspace.isRunning($0.bundleId) && workspace.frontmostBundleId() == $0.bundleId })
            ?? PresenterApp.allCases.first(where: { $0 != .preview && workspace.isRunning($0.bundleId) }),
              let script = app.stateScript else { return emit(.notPresenting) }
        polling = true
        scripts.run(script) { [weak self] outcome in
            guard let self else { return }
            self.queue.async {
                self.polling = false
                guard self.watching else { return }
                self.emit(Self.state(for: app, outcome))
            }
        }
    }

    private func emit(_ s: PresentState) {
        guard s != lastPublished else { return }
        lastPublished = s
        publish(s)
    }

    static func state(for app: PresenterApp, _ outcome: ScriptOutcome) -> PresentState {
        switch outcome {
        case .denied: return PresentState(active: true, app: app.name, error: "automation")
        case .failed: return .notPresenting
        case let .ok(items):
            guard items.first == "playing" else { return .notPresenting }
            let index = items.count > 1 ? Int(items[1]) : nil
            let count = items.count > 2 ? Int(items[2]) : nil
            let notes = items.count > 3 ? items[3] : nil
            let title = items.count > 4 ? items[4] : nil
            return PresentState(active: true, app: app.name, index: index, count: count, notes: notes, title: title)
        }
    }
}

// MARK: - The Mac's own media

/// Decides when a new `mac.media` is worth sending: on change only, and never on a timer. The phone extrapolates the position.
struct MediaChangeDetector {
    private var last: MacMedia?
    private var sentArtFor: String?
    /// How far the real position may drift from the extrapolated one before it counts as a seek.
    static let seekToleranceMs: Int64 = 1500

    /// The message to send, or nil when the phone already knows. `art` is attached once per track, when it is available.
    mutating func next(_ m: MacMedia, art: Data?) -> MacMedia? {
        var out = m
        if m.active, let art, sentArtFor != m.trackKey { out.art = art }
        guard changed(from: last, to: out) else { return nil }
        last = out
        if out.art != nil { sentArtFor = out.trackKey }
        if !m.active { sentArtFor = nil }
        return out
    }

    mutating func reset() { last = nil; sentArtFor = nil }

    private func changed(from old: MacMedia?, to new: MacMedia) -> Bool {
        guard let old else { return true }
        if old.active != new.active || old.error != new.error { return true }
        if let a = old.volume, let b = new.volume { if abs(a - b) >= 0.01 { return true } } else if (old.volume == nil) != (new.volume == nil) { return true }
        guard new.active else { return false }
        if old.trackKey != new.trackKey || old.playing != new.playing || old.durationMs != new.durationMs || old.canSeek != new.canSeek { return true }
        if new.art != nil { return true }
        let expected = old.positionMs + (old.playing ? max(0, new.ts - old.ts) : 0)
        return abs(new.positionMs - expected) > Self.seekToleranceMs
    }
}

public enum MediaPlayer: CaseIterable, Sendable {
    case music, spotify

    var bundleId: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    var name: String { self == .music ? "Music" : "Spotify" }

    var stateScript: String {
        switch self {
        case .music:
            return """
            with timeout of 3 seconds
            tell application "Music"
              if player state is stopped then return {"stopped"}
              set t to current track
              return {(player state as text), name of t, artist of t, album of t, (player position as text), ((duration of t) as text), ""}
            end tell
            end timeout
            """
        case .spotify:
            return """
            with timeout of 3 seconds
            tell application "Spotify"
              if player state is stopped then return {"stopped"}
              set t to current track
              return {(player state as text), name of t, artist of t, album of t, (player position as text), ((duration of t) as text), (artwork url of t)}
            end tell
            end timeout
            """
        }
    }

    /// Music's artwork comes as picture data. Spotify hands over a URL in the state script.
    var artScript: String? {
        self == .music ? "with timeout of 3 seconds\ntell application \"Music\" to get data of artwork 1 of current track\nend timeout" : nil
    }

    func commandScript(_ c: MacMediaCommand) -> String {
        let t = "tell application \"\(name)\" to "
        switch c {
        case .toggle: return t + "playpause"
        case .next: return t + "next track"
        case .prev: return t + "previous track"
        case let .seek(ms): return t + "set player position to \(Double(ms) / 1000)"
        case .volume: return ""
        }
    }

    /// Spotify reports its duration in milliseconds, Music in seconds. Positions are seconds for both.
    var durationIsMs: Bool { self == .spotify }
}

public final class MediaService {
    private let workspace: AppWorkspace
    private let scripts: ScriptRunning
    private let artwork: ArtworkEncoding
    private let queue: DispatchQueue
    private let publish: @Sendable (MacMedia) -> Void
    private let now: @Sendable () -> Date
    private let pollInterval: TimeInterval

    private var watching = false
    private var polling = false
    private var timer: DispatchSourceTimer?
    private var detector = MediaChangeDetector()
    private var artCache: (key: String, data: Data?)?
    private var artFetching: String?

    public static let artPixels = 400

    public init(workspace: AppWorkspace, scripts: ScriptRunning, artwork: ArtworkEncoding, queue: DispatchQueue = DispatchQueue(label: "mydroid.media"),
                pollInterval: TimeInterval = 1.0, now: @escaping @Sendable () -> Date = Date.init, publish: @escaping @Sendable (MacMedia) -> Void) {
        self.workspace = workspace; self.scripts = scripts; self.artwork = artwork; self.queue = queue
        self.pollInterval = pollInterval; self.now = now; self.publish = publish
    }

    public func setWatching(_ on: Bool) {
        queue.async {
            guard on != self.watching else { return }
            self.watching = on
            self.detector.reset()
            if on {
                let t = DispatchSource.makeTimerSource(queue: self.queue)
                t.schedule(deadline: .now(), repeating: self.pollInterval)
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                self.timer = t
            } else { self.timer?.cancel(); self.timer = nil }
        }
    }

    func tick() {
        guard watching, !polling else { return }
        polling = true
        let running = MediaPlayer.allCases.filter { workspace.isRunning($0.bundleId) }
        read(running, found: []) { [weak self] result in
            guard let self else { return }
            self.queue.async { self.polling = false; self.finish(result) }
        }
    }

    private struct Reading { var player: MediaPlayer; var items: [String] }
    private enum ReadResult { case none, denied, found(Reading) }

    /// Asks each running player in turn; the first one that is playing wins, else the first with a track.
    private func read(_ players: [MediaPlayer], found: [Reading], denied: Bool = false, done: @escaping @Sendable (ReadResult) -> Void) {
        guard let p = players.first else {
            if let playing = found.first(where: { $0.items.first == "playing" }) ?? found.first { return done(.found(playing)) }
            return done(denied ? .denied : .none)
        }
        scripts.run(p.stateScript) { [weak self] outcome in
            guard let self else { return }
            var f = found; var d = denied
            switch outcome {
            case let .ok(items) where items.count >= 6 && items[0] != "stopped": f.append(Reading(player: p, items: items))
            case .denied: d = true
            default: break
            }
            self.read(Array(players.dropFirst()), found: f, denied: d, done: done)
        }
    }

    private func finish(_ r: ReadResult) {
        guard watching else { return }
        readVolume { [weak self] volume in
            guard let self else { return }
            self.queue.async {
                guard self.watching else { return }
                switch r {
                case .none: self.send(MacMedia(active: false, volume: volume), art: nil)
                case .denied: self.send(MacMedia(active: false, volume: volume, error: "automation"), art: nil)
                case let .found(reading):
                    let m = Self.media(from: reading.player, reading.items, volume: volume, ts: Int64(self.now().timeIntervalSince1970 * 1000))
                    self.withArt(for: m, player: reading.player, urlText: reading.items.count > 6 ? reading.items[6] : "") { art in
                        self.queue.async { self.send(m, art: art) }
                    }
                }
            }
        }
    }

    private func send(_ m: MacMedia, art: Data?) {
        guard watching, let out = detector.next(m, art: art) else { return }
        publish(out)
    }

    static func media(from p: MediaPlayer, _ items: [String], volume: Double?, ts: Int64) -> MacMedia {
        func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0 }
        let duration = p.durationIsMs ? num(items[5]) : num(items[5]) * 1000
        return MacMedia(active: true, app: p.name, title: items[1], artist: items[2], album: items[3], playing: items[0] == "playing",
                        positionMs: Int64(num(items[4]) * 1000), durationMs: Int64(duration), ts: ts, canSeek: true, volume: volume)
    }

    private func readVolume(_ done: @escaping @Sendable (Double?) -> Void) {
        scripts.run("return output volume of (get volume settings)") { outcome in
            if case let .ok(items) = outcome, let s = items.first, let v = Double(s) { done(min(1, max(0, v / 100))) } else { done(nil) }
        }
    }

    // MARK: Artwork

    /// The cover for a track, fetched once and kept for as long as the track stays the same.
    private func withArt(for m: MacMedia, player: MediaPlayer, urlText: String, done: @escaping @Sendable (Data?) -> Void) {
        let key = m.trackKey
        if let c = artCache, c.key == key { return done(c.data) }
        guard artFetching != key else { return done(nil) }
        artFetching = key
        let finish: @Sendable (Data?) -> Void = { [weak self] raw in
            guard let self else { return done(nil) }
            let jpeg = raw.flatMap { self.artwork.jpeg(from: $0, maxPixel: Self.artPixels) }
            self.queue.async { self.artCache = (key, jpeg); self.artFetching = nil; done(jpeg) }
        }
        if let script = player.artScript {
            scripts.runData(script, completion: finish)
        } else if let url = URL(string: urlText), url.scheme == "https" {
            artwork.fetch(url, completion: finish)
        } else {
            finish(nil)
        }
    }

    // MARK: Commands

    public func command(_ c: MacMediaCommand) {
        if case let .volume(v) = c {
            scripts.run("set volume output volume \(Int((v * 100).rounded()))") { _ in }
            return
        }
        // The player that is playing, else the first one running.
        let running = MediaPlayer.allCases.filter { workspace.isRunning($0.bundleId) }
        guard !running.isEmpty else { return }
        pick(running) { [weak self] p in
            guard let self, let p else { return }
            self.scripts.run(p.commandScript(c)) { _ in }
        }
    }

    private func pick(_ players: [MediaPlayer], done: @escaping @Sendable (MediaPlayer?) -> Void) {
        guard let p = players.first else { return done(nil) }
        if players.count == 1 { return done(p) }
        scripts.run(p.stateScript) { [weak self] outcome in
            if case let .ok(items) = outcome, items.first == "playing" { return done(p) }
            self?.pick(Array(players.dropFirst()), done: done) ?? done(nil)
        }
    }
}

// MARK: - Everything behind `MacRemoteHandling`

public final class MacRemoteService: MacRemoteHandling {
    private let workspace: AppWorkspace
    private let present: PresentService
    private let media: MediaService
    private var cachedInstalled: (at: Date, apps: [MacAppInfo])?

    public init(workspace: AppWorkspace, present: PresentService, media: MediaService) {
        self.workspace = workspace; self.present = present; self.media = media
    }

    public func apps(completion: @escaping @Sendable (AppsListing) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let running = self.workspace.runningApps(limit: 16)
            let installed = self.installed()
            completion(AppsListing(running: running, installed: installed))
        }
    }

    /// Scanning /Applications reads every Info.plist; a minute is soon enough to notice a new app.
    private func installed() -> [MacAppInfo] {
        if let c = cachedInstalled, Date().timeIntervalSince(c.at) < 60 { return c.apps }
        let apps = workspace.installedApps()
        cachedInstalled = (Date(), apps)
        return apps
    }

    public func launch(_ bundleId: String, completion: @escaping @Sendable (MacActionResult) -> Void) { workspace.launch(bundleId, completion: completion) }
    public func open(_ url: URL, completion: @escaping @Sendable (MacActionResult) -> Void) { workspace.open(url, completion: completion) }
    public func present(_ url: URL, play: Bool, completion: @escaping @Sendable (MacActionResult) -> Void) { present.start(url, play: play, completion: completion) }
    public func setPresentWatching(_ on: Bool) { present.setWatching(on) }
    public func setMediaWatching(_ on: Bool) { media.setWatching(on) }
    public func mediaCommand(_ c: MacMediaCommand) { media.command(c) }
}
