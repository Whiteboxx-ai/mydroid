import XCTest
@testable import MydroidCore

// PROTOCOL.md section 16.

// MARK: - Fakes

final class FakeWorkspace: AppWorkspace, @unchecked Sendable {
    var running: [MacAppInfo] = []
    var installed: [MacAppInfo] = []
    var front: String?
    var defaultApp: String?
    var opened: [URL] = []
    var launched: [String] = []
    var openResult = MacActionResult.success
    /// After this many `frontmostBundleId()` calls the default app is in front (simulates a slow launch).
    var comesForwardAfter = 0
    private var calls = 0
    func runningApps(limit: Int) -> [MacAppInfo] { Array(running.prefix(limit)) }
    func installedApps() -> [MacAppInfo] { installed }
    func isRunning(_ b: String) -> Bool { running.contains { $0.id == b } }
    func frontmostBundleId() -> String? {
        calls += 1
        if comesForwardAfter > 0 { return calls > comesForwardAfter ? defaultApp : "com.apple.finder" }
        return front
    }
    func launch(_ b: String, completion: @escaping @Sendable (MacActionResult) -> Void) { launched.append(b); completion(.success) }
    func open(_ url: URL, completion: @escaping @Sendable (MacActionResult) -> Void) { opened.append(url); completion(openResult) }
    func defaultAppId(for url: URL) -> String? { defaultApp }
}

final class FakeScripts: ScriptRunning, @unchecked Sendable {
    var sources: [String] = []
    /// Matched by substring of the script, first hit wins.
    var results: [(contains: String, outcome: ScriptOutcome)] = []
    var data: Data?
    func run(_ source: String, completion: @escaping @Sendable (ScriptOutcome) -> Void) {
        sources.append(source)
        completion(results.first { source.contains($0.contains) }?.outcome ?? .ok([]))
    }
    func runData(_ source: String, completion: @escaping @Sendable (Data?) -> Void) { sources.append(source); completion(data) }
}

final class FakeArtwork: ArtworkEncoding, @unchecked Sendable {
    var fetched: [URL] = []
    func jpeg(from data: Data, maxPixel: Int) -> Data? { Data("jpeg:".utf8) + data }
    func fetch(_ url: URL, completion: @escaping @Sendable (Data?) -> Void) { fetched.append(url); completion(Data("net".utf8)) }
}

final class FakeRemote: MacRemoteHandling, @unchecked Sendable {
    var listing = AppsListing(running: [], installed: [])
    var launched: [String] = []
    var opened: [URL] = []
    var presented: [(URL, Bool)] = []
    var presentWatching: [Bool] = []
    var mediaWatching: [Bool] = []
    var commands: [MacMediaCommand] = []
    var result = MacActionResult.success
    func apps(completion: @escaping @Sendable (AppsListing) -> Void) { completion(listing) }
    func launch(_ id: String, completion: @escaping @Sendable (MacActionResult) -> Void) { launched.append(id); completion(result) }
    func open(_ url: URL, completion: @escaping @Sendable (MacActionResult) -> Void) { opened.append(url); completion(result) }
    func present(_ url: URL, play: Bool, completion: @escaping @Sendable (MacActionResult) -> Void) { presented.append((url, play)); completion(result) }
    func setPresentWatching(_ on: Bool) { presentWatching.append(on) }
    func setMediaWatching(_ on: Bool) { mediaWatching.append(on) }
    func mediaCommand(_ c: MacMediaCommand) { commands.append(c) }
}

final class Collected<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ t: T) { lock.lock(); items.append(t); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

// MARK: - osascript

final class OsascriptRunnerTests: XCTestCase {
    func testListComesBackSplitOnTheUnitSeparatorSoCommasSurvive() {
        let r = CommandResult(output: "playing\u{1F}Hello, World\u{1F}A, B\u{1F}Album\n")
        XCTAssertEqual(OsascriptRunner.outcome(r), .ok(["playing", "Hello, World", "A, B", "Album"]))
    }

    func testEmptyOutputIsAnEmptyList() { XCTAssertEqual(OsascriptRunner.outcome(CommandResult(output: "\n")), .ok([])) }

    func testNotAuthorizedIsDeniedNotAFailure() {
        let e = "execution error: Not authorized to send Apple events to Music. (-1743)"
        XCTAssertEqual(OsascriptRunner.outcome(CommandResult(status: 1, error: e)), .denied)
    }

    func testAnAppThatIsNotThereOrAHungOneIsAFailure() {
        if case .failed = OsascriptRunner.outcome(CommandResult(status: 1, error: "Application isn’t running. (-600)")) {} else { XCTFail() }
        if case .failed = OsascriptRunner.outcome(CommandResult(stillRunning: true)) {} else { XCTFail("a script that timed out") }
        if case .failed = OsascriptRunner.outcome(CommandResult(launchFailed: true)) {} else { XCTFail() }
    }

    func testPictureDataLiteralDecodes() {
        XCTAssertEqual(OsascriptRunner.dataLiteral("«data TIFF49492a00»\n"), Data([0x49, 0x49, 0x2a, 0x00]))
        XCTAssertNil(OsascriptRunner.dataLiteral("missing value"))
        XCTAssertNil(OsascriptRunner.dataLiteral("«data TIFF4»"), "an odd number of hex digits is damaged data")
        XCTAssertNil(OsascriptRunner.dataLiteral("«data TIFFzz»"))
    }
}

// MARK: - Presenting

final class PresentServiceTests: XCTestCase {
    let ws = FakeWorkspace()
    let scripts = FakeScripts()
    let poster = RecordingPoster()
    let queue = DispatchQueue(label: "test.present")
    let published = Collected<PresentState>()
    let deck = URL(fileURLWithPath: "/tmp/deck.key")

    func service() -> PresentService {
        let p = published
        return PresentService(workspace: ws, scripts: scripts, poster: poster, queue: queue, pollInterval: 0.02,
                              after: { _, work in work() }, publish: { p.add($0) })
    }

    func start(_ s: PresentService, play: Bool = true) -> MacActionResult {
        var r: MacActionResult?
        s.start(deck, play: play) { r = $0 }
        return r!
    }

    func testKeynoteDeckOpensThenPlaysThroughScripting() {
        ws.defaultApp = PresenterApp.keynote.bundleId; ws.front = PresenterApp.keynote.bundleId
        scripts.results = [("start front document", .ok([]))]
        XCTAssertEqual(start(service()), .success)
        XCTAssertEqual(ws.opened, [deck])
        XCTAssertTrue(scripts.sources.contains { $0.contains("start front document") })
        XCTAssertTrue(poster.events.isEmpty, "no keystrokes when the script worked")
    }

    func testWithoutAutomationKeynoteIsStartedWithItsKeyboardShortcut() {
        ws.defaultApp = PresenterApp.keynote.bundleId; ws.front = PresenterApp.keynote.bundleId
        scripts.results = [("start front document", .denied)]
        XCTAssertEqual(start(service()), .success)
        XCTAssertEqual(poster.events, [.key(code: 0x23, down: true, flags: [.option, .command]), .key(code: 0x23, down: false, flags: [.option, .command])])
    }

    func testPowerPointAndPreviewUseTheirShortcuts() {
        ws.defaultApp = PresenterApp.powerPoint.bundleId; ws.front = ws.defaultApp
        XCTAssertEqual(start(service()), .success)
        XCTAssertEqual(poster.events.first, .key(code: 0x24, down: true, flags: [.shift, .command]))
        poster.events.removeAll()
        ws.defaultApp = PresenterApp.preview.bundleId; ws.front = ws.defaultApp
        XCTAssertEqual(start(service()), .success)
        XCTAssertEqual(poster.events.first, .key(code: 0x03, down: true, flags: [.shift, .command]))
    }

    func testPlayWaitsForTheAppToComeForward() {
        ws.defaultApp = PresenterApp.keynote.bundleId; ws.comesForwardAfter = 3
        scripts.results = [("start front document", .ok([]))]
        XCTAssertEqual(start(service()), .success)
        XCTAssertGreaterThanOrEqual(ws.opened.count, 1)
    }

    func testJustOpenDoesNotPlay() {
        ws.defaultApp = PresenterApp.keynote.bundleId; ws.front = ws.defaultApp
        XCTAssertEqual(start(service(), play: false), .success)
        XCTAssertTrue(scripts.sources.isEmpty); XCTAssertTrue(poster.events.isEmpty)
    }

    func testAnOpenThatFailsIsReportedAndNothingElseHappens() {
        ws.defaultApp = PresenterApp.keynote.bundleId; ws.openResult = .failure("no such file")
        XCTAssertEqual(start(service()), .failure("no such file"))
        XCTAssertTrue(scripts.sources.isEmpty)
    }

    func testAnUnknownAppJustOpensTheFile() {
        ws.defaultApp = "com.example.Slides"
        XCTAssertEqual(start(service()), .success)
        XCTAssertTrue(scripts.sources.isEmpty); XCTAssertTrue(poster.events.isEmpty)
    }

    func testKeynoteStateParses() {
        let s = PresentService.state(for: .keynote, .ok(["playing", "7", "24", "Pause here.", "Revenue by region"]))
        XCTAssertEqual(s, PresentState(active: true, app: "Keynote", index: 7, count: 24, notes: "Pause here.", title: "Revenue by region"))
        XCTAssertEqual(PresentService.state(for: .keynote, .ok(["stopped"])), .notPresenting)
        XCTAssertEqual(PresentService.state(for: .keynote, .failed("x")), .notPresenting)
        XCTAssertEqual(PresentService.state(for: .keynote, .denied), PresentState(active: true, app: "Keynote", error: "automation"))
        XCTAssertEqual(PresentService.state(for: .powerPoint, .ok(["playing", "2", "9", "", ""])).index, 2)
    }

    func testWireFieldsLeaveOutWhatIsUnknownAndClipLongNotes() {
        XCTAssertEqual(PresentState.notPresenting.wireFields as NSDictionary, ["active": false])
        let f = PresentState(active: true, app: "Keynote", index: 1, count: 2, notes: String(repeating: "é", count: 5000)).wireFields
        XCTAssertLessThanOrEqual((f["notes"] as! String).utf8.count, 4096)
        XCTAssertNil(f["title"])
        XCTAssertEqual(f["index"] as? Int, 1)
    }

    func testWatchingPublishesWhenSomethingChangesAndNotBefore() {
        ws.running = [MacAppInfo(id: PresenterApp.keynote.bundleId, name: "Keynote")]; ws.front = PresenterApp.keynote.bundleId
        scripts.results = [("playing", .ok(["playing", "3", "10", "n", "t"]))]
        let s = service()
        s.setWatching(true)
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(published.all, [PresentState(active: true, app: "Keynote", index: 3, count: 10, notes: "n", title: "t")], "the same slide is not sent twice")
        scripts.results = [("playing", .ok(["playing", "4", "10", "n2", "t2"]))]
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(published.all.last?.index, 4)
        XCTAssertEqual(published.all.count, 2)
        s.setWatching(false)
        queue.sync {}
        let n = scripts.sources.count
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(scripts.sources.count, n, "no scripts run once the phone stopped watching")
    }

    func testNothingRunningMeansNotPresenting() {
        let s = service()
        s.setWatching(true)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(published.all, [.notPresenting])
        XCTAssertTrue(scripts.sources.isEmpty, "an app that isn't running is never scripted (that would launch it)")
        s.setWatching(false)
    }
}

// MARK: - Media

final class MediaChangeDetectorTests: XCTestCase {
    private func m(playing: Bool = true, pos: Int64 = 10_000, ts: Int64 = 1_000_000, title: String = "Slow Tide", volume: Double? = 0.5) -> MacMedia {
        MacMedia(active: true, app: "Music", title: title, artist: "Northern Lights", album: "Blue Hour", playing: playing, positionMs: pos, durationMs: 200_000, ts: ts, volume: volume)
    }

    func testTheFirstReadingIsSent() {
        var d = MediaChangeDetector()
        XCTAssertNotNil(d.next(m(), art: nil))
    }

    func testPlayingAlongIsNotResentButASeekIs() {
        var d = MediaChangeDetector()
        _ = d.next(m(), art: nil)
        XCTAssertNil(d.next(m(pos: 11_000, ts: 1_001_000), art: nil), "one second later at one second more: nothing to say, the phone extrapolates")
        XCTAssertNil(d.next(m(pos: 20_300, ts: 1_010_000), art: nil), "small drift is fine")
        XCTAssertNotNil(d.next(m(pos: 90_000, ts: 1_011_000), art: nil), "a jump is a seek")
    }

    func testPausingResumingAndTrackChangesAreSent() {
        var d = MediaChangeDetector()
        _ = d.next(m(), art: nil)
        XCTAssertNotNil(d.next(m(playing: false), art: nil))
        XCTAssertNil(d.next(m(playing: false, ts: 1_005_000), art: nil), "paused: the position doesn't move")
        XCTAssertNotNil(d.next(m(playing: true, ts: 1_006_000), art: nil))
        XCTAssertNotNil(d.next(m(ts: 1_007_000, title: "Another"), art: nil))
    }

    func testVolumeChangesAreSentButNotNoise() {
        var d = MediaChangeDetector()
        _ = d.next(m(), art: nil)
        XCTAssertNil(d.next(m(pos: 11_000, ts: 1_001_000, volume: 0.505), art: nil))
        XCTAssertNotNil(d.next(m(pos: 12_000, ts: 1_002_000, volume: 0.6), art: nil))
    }

    func testArtIsAttachedOncePerTrack() {
        var d = MediaChangeDetector()
        let first = d.next(m(), art: nil)
        XCTAssertNil(first?.art)
        let withArt = d.next(m(pos: 11_000, ts: 1_001_000), art: Data("cover".utf8))
        XCTAssertEqual(withArt?.art, Data("cover".utf8), "the cover arrives when it is ready, as its own message")
        XCTAssertNil(d.next(m(pos: 12_000, ts: 1_002_000), art: Data("cover".utf8)), "and not again for the same track")
        XCTAssertNotNil(d.next(m(ts: 1_003_000, title: "Another"), art: Data("cover2".utf8)))
    }

    func testGoingQuietAndComingBackIsSent() {
        var d = MediaChangeDetector()
        _ = d.next(m(), art: nil)
        XCTAssertNotNil(d.next(MacMedia(active: false, volume: 0.5), art: nil))
        XCTAssertNil(d.next(MacMedia(active: false, volume: 0.5), art: nil))
        XCTAssertNotNil(d.next(MacMedia(active: false, volume: 0.5, error: "automation"), art: nil))
    }
}

final class MediaServiceTests: XCTestCase {
    let ws = FakeWorkspace()
    let scripts = FakeScripts()
    let art = FakeArtwork()
    let queue = DispatchQueue(label: "test.media")
    let published = Collected<MacMedia>()

    func service() -> MediaService {
        let p = published
        return MediaService(workspace: ws, scripts: scripts, artwork: art, queue: queue, pollInterval: 0.02, now: { Date(timeIntervalSince1970: 1000) }, publish: { p.add($0) })
    }

    func testMusicReadingBecomesMedia() {
        let m = MediaService.media(from: .music, ["playing", "Slow Tide", "Northern Lights", "Blue Hour", "102,5", "238.2", ""], volume: 0.4, ts: 5)
        XCTAssertEqual(m.app, "Music"); XCTAssertEqual(m.title, "Slow Tide"); XCTAssertTrue(m.playing)
        XCTAssertEqual(m.positionMs, 102_500, "a comma is a decimal point in some languages")
        XCTAssertEqual(m.durationMs, 238_200)
    }

    func testSpotifyDurationIsAlreadyMilliseconds() {
        let m = MediaService.media(from: .spotify, ["paused", "t", "a", "b", "12.0", "180000", "https://i.scdn.co/x"], volume: nil, ts: 0)
        XCTAssertEqual(m.durationMs, 180_000); XCTAssertFalse(m.playing)
    }

    func testWatchingPublishesTheCurrentSongWithItsCoverOnce() {
        ws.running = [MacAppInfo(id: MediaPlayer.music.bundleId, name: "Music")]
        scripts.results = [("player state", .ok(["playing", "Slow Tide", "Northern Lights", "Blue Hour", "10.0", "200.0", ""])), ("output volume", .ok(["50"]))]
        scripts.data = Data("tiff".utf8)
        let s = service()
        s.setWatching(true)
        Thread.sleep(forTimeInterval: 0.25)
        s.setWatching(false)
        let got = published.all
        XCTAssertEqual(got.first?.title, "Slow Tide")
        XCTAssertEqual(got.first?.volume ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(got.compactMap(\.art).count, 1, "the cover is sent once")
        XCTAssertEqual(got.compactMap(\.art).first, Data("jpeg:tiff".utf8))
    }

    func testSpotifyCoverIsFetchedFromItsHttpsUrlOnly() {
        ws.running = [MacAppInfo(id: MediaPlayer.spotify.bundleId, name: "Spotify")]
        scripts.results = [("player state", .ok(["playing", "t", "a", "b", "1", "100000", "https://i.scdn.co/image/abc"]))]
        let s = service()
        s.setWatching(true); Thread.sleep(forTimeInterval: 0.15); s.setWatching(false)
        XCTAssertEqual(art.fetched.map(\.absoluteString), ["https://i.scdn.co/image/abc"])
        art.fetched.removeAll()
        scripts.results = [("player state", .ok(["playing", "t2", "a", "b", "1", "100000", "file:///etc/passwd"]))]
        let s2 = service()
        s2.setWatching(true); Thread.sleep(forTimeInterval: 0.15); s2.setWatching(false)
        XCTAssertTrue(art.fetched.isEmpty, "only https artwork is fetched")
    }

    func testPlayersThatAreNotRunningAreNeverScripted() {
        let s = service()
        s.setWatching(true); Thread.sleep(forTimeInterval: 0.1); s.setWatching(false)
        XCTAssertFalse(scripts.sources.contains { $0.contains("tell application \"Music\"") || $0.contains("tell application \"Spotify\"") })
        XCTAssertEqual(published.all.first?.active, false)
    }

    func testDeniedAutomationIsReportedAsSuch() {
        ws.running = [MacAppInfo(id: MediaPlayer.music.bundleId, name: "Music")]
        scripts.results = [("player state", .denied)]
        let s = service()
        s.setWatching(true); Thread.sleep(forTimeInterval: 0.1); s.setWatching(false)
        XCTAssertEqual(published.all.first?.error, "automation")
    }

    func testTheOneThatIsPlayingWinsOverAPausedOne() {
        ws.running = [MacAppInfo(id: MediaPlayer.music.bundleId, name: "Music"), MacAppInfo(id: MediaPlayer.spotify.bundleId, name: "Spotify")]
        scripts.results = [("tell application \"Music\"", .ok(["paused", "old", "a", "b", "1", "100", ""])),
                           ("tell application \"Spotify\"", .ok(["playing", "now", "a", "b", "1", "100000", ""]))]
        let s = service()
        s.setWatching(true); Thread.sleep(forTimeInterval: 0.1); s.setWatching(false)
        XCTAssertEqual(published.all.first?.title, "now")
    }

    func testCommandsGoToThePlayerThatIsPlayingAndVolumeIsSystemWide() {
        ws.running = [MacAppInfo(id: MediaPlayer.music.bundleId, name: "Music")]
        let s = service()
        s.command(.next); s.command(.seek(positionMs: 61_500)); s.command(.volume(0.25))
        XCTAssertTrue(scripts.sources.contains("tell application \"Music\" to next track"))
        XCTAssertTrue(scripts.sources.contains("tell application \"Music\" to set player position to 61.5"))
        XCTAssertTrue(scripts.sources.contains("set volume output volume 25"))
    }

    func testCommandParsing() {
        func c(_ f: [String: Any]) -> MacMediaCommand? { MacMediaCommand(message: Message("mac.media.cmd", f)) }
        XCTAssertEqual(c(["action": "toggle"]), .toggle)
        XCTAssertEqual(c(["action": "seek", "position": 5000]), .seek(positionMs: 5000))
        XCTAssertEqual(c(["action": "volume", "value": 1.7]), .volume(1))
        XCTAssertNil(c(["action": "seek"])); XCTAssertNil(c(["action": "seek", "position": -1])); XCTAssertNil(c(["action": "explode"]))
    }
}

// MARK: - Over the wire

final class HubRemoteV2Tests: HubFixtureCase {
    var tree: URL!
    let remote = FakeRemote()

    override func setUp() async throws {
        try await super.setUp()
        tree = URL(fileURLWithPath: SharePath.realpath(NSTemporaryDirectory())!).appendingPathComponent("mydroid-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("root/Work"), withIntermediateDirectories: true)
        try Data("deck".utf8).write(to: tree.appendingPathComponent("root/Work/Q3.key"))
        try Data("secret".utf8).write(to: tree.appendingPathComponent("secret.txt"))
        hub.macRemote = remote
        try await pairAndConnect()
        hub.setFileShare(FileShareConfig(enabled: true, roots: [ShareRoot(id: "docs", name: "Documents", url: tree.appendingPathComponent("root"), writable: false)]))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tree)
        try await super.tearDown()
    }

    func expectBool(_ type: String, _ key: String, _ want: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
        let m = try await phone.receive(type: type)
        XCTAssertEqual(m.bool(key), want, message, file: file, line: line)
    }

    func testAppsListCarriesIconsOnlyForRunningApps() async throws {
        remote.listing = AppsListing(running: [MacAppInfo(id: "com.apple.Safari", name: "Safari", icon: Data([1, 2, 3]))],
                                     installed: [MacAppInfo(id: "com.apple.Safari", name: "Safari"), MacAppInfo(id: "com.apple.Notes", name: "Notes")])
        try await phone.send(Message("mac.apps.get", ["req": 4]))
        let r = try await phone.receive(type: "mac.apps")
        XCTAssertEqual(r.int("req"), 4)
        let running = try XCTUnwrap(r.fields["running"] as? [[String: Any]])
        XCTAssertEqual(running.first?["icon"] as? String, Data([1, 2, 3]).base64EncodedString())
        let apps = try XCTUnwrap(r.fields["apps"] as? [[String: Any]])
        XCTAssertEqual(apps.map { $0["name"] as? String }, ["Safari", "Notes"])
        XCTAssertNil(apps.first?["icon"])
    }

    func testLaunchAnAppById() async throws {
        try await phone.send(Message("mac.launch", ["req": "a", "id": "com.apple.Notes"]))
        let r = try await phone.receive(type: "mac.result")
        XCTAssertEqual(r.string("req"), "a"); XCTAssertEqual(r.bool("ok"), true)
        XCTAssertEqual(remote.launched, ["com.apple.Notes"])
        try await phone.send(Message("mac.launch", ["req": "b"]))
        try await expectBool("mac.result", "ok", false)
    }

    func testOpenOnlyReachesFilesInsideTheSharedFolders() async throws {
        try await phone.send(Message("mac.open", ["req": 1, "root": "docs", "path": "Work/Q3.key"]))
        try await expectBool("mac.result", "ok", true)
        XCTAssertEqual(remote.opened.map(\.lastPathComponent), ["Q3.key"])

        for (i, bad) in ["../secret.txt", "/etc/passwd", "Work/../../secret.txt", ".git/config"].enumerated() {
            try await phone.send(Message("mac.open", ["req": 10 + i, "root": "docs", "path": bad]))
            try await expectBool("mac.result", "ok", false, bad)
        }
        try await phone.send(Message("mac.open", ["req": 20, "root": "nope", "path": "Work/Q3.key"]))
        try await expectBool("mac.result", "ok", false)
        XCTAssertEqual(remote.opened.count, 1, "nothing outside the share was ever opened")
    }

    func testOpeningIsRefusedWhenSharingIsOff() async throws {
        hub.setFileShare(FileShareConfig(enabled: false, roots: []))
        try await phone.send(Message("mac.open", ["req": 1, "root": "docs", "path": "Work/Q3.key"]))
        let r = try await phone.receive(type: "mac.result")
        XCTAssertEqual(r.bool("ok"), false)
        XCTAssertTrue(remote.opened.isEmpty)
    }

    func testPresentStartNeedsARegularFileAndPassesPlay() async throws {
        try await phone.send(Message("present.start", ["req": 1, "root": "docs", "path": "Work/Q3.key", "play": true]))
        try await expectBool("mac.result", "ok", true)
        XCTAssertEqual(remote.presented.first?.1, true)
        try await phone.send(Message("present.start", ["req": 2, "root": "docs", "path": "Work", "play": true]))
        try await expectBool("mac.result", "ok", false, "a folder is not a deck")
        XCTAssertEqual(remote.presented.count, 1)
    }

    func testPresentStateOnlyFlowsWhileTheyAreWatching() async throws {
        hub.setPresentState(PresentState(active: true, app: "Keynote", index: 1, count: 3))   // nobody asked yet
        try await phone.send(Message("present.watch", ["on": true]))
        try await phone.send(Message("ping")); _ = try await phone.receive(type: "pong")
        XCTAssertEqual(remote.presentWatching, [true])
        hub.setPresentState(PresentState(active: true, app: "Keynote", index: 2, count: 3, notes: "hello"))
        let s = try await phone.receive(type: "present.state")
        XCTAssertEqual(s.int("index"), 2); XCTAssertEqual(s.string("notes"), "hello"); XCTAssertEqual(s.string("app"), "Keynote")
        hub.setPresentState(PresentState(active: true, app: "Keynote", index: 2, count: 3, notes: "hello"))   // same: not sent
        hub.setPresentState(PresentState.notPresenting)
        try await expectBool("present.state", "active", false)
        try await phone.send(Message("present.watch", ["on": false]))
        try await phone.send(Message("ping")); _ = try await phone.receive(type: "pong")
        XCTAssertEqual(remote.presentWatching, [true, false])
    }

    func testMacMediaFlowsAndCommandsArrive() async throws {
        try await phone.send(Message("mac.media.watch", ["on": true]))
        try await phone.send(Message("mac.media.cmd", ["action": "seek", "position": 4000]))
        try await phone.send(Message("mac.media.cmd", ["action": "volume", "value": 0.3]))
        try await phone.send(Message("mac.media.cmd", ["action": "bogus"]))
        try await phone.send(Message("ping")); _ = try await phone.receive(type: "pong")
        XCTAssertEqual(remote.mediaWatching, [true])
        XCTAssertEqual(remote.commands, [.seek(positionMs: 4000), .volume(0.3)])
        hub.setMacMedia(MacMedia(active: true, app: "Music", title: "Slow Tide", artist: "NL", album: "BH", playing: true, positionMs: 1000, durationMs: 200_000, ts: 9, art: Data("c".utf8), volume: 0.5))
        let m = try await phone.receive(type: "mac.media")
        XCTAssertEqual(m.string("title"), "Slow Tide"); XCTAssertEqual(m.bool("playing"), true); XCTAssertEqual(m.int("position"), 1000)
        XCTAssertEqual(m.string("art"), Data("c".utf8).base64EncodedString())
        XCTAssertEqual(m.double("volume") ?? 0, 0.5, accuracy: 0.001)
    }

    func testWatchersAreStoppedWhenThePhoneLeaves() async throws {
        try await phone.send(Message("present.watch", ["on": true]))
        try await phone.send(Message("mac.media.watch", ["on": true]))
        try await phone.send(Message("ping")); _ = try await phone.receive(type: "pong")
        phone.drop()
        for _ in 0..<200 where remote.presentWatching.last != false { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(remote.presentWatching, [true, false])
        XCTAssertEqual(remote.mediaWatching, [true, false])
    }

    func testWithoutAServiceTheAppsListIsEmptyAndRequestsAreAnsweredUnsupported() async throws {
        hub.macRemote = nil
        try await phone.send(Message("mac.apps.get", ["req": 1]))
        let none = try await phone.receive(type: "mac.apps")
        XCTAssertEqual((none.fields["running"] as? [Any])?.count, 0)
        try await phone.send(Message("mac.launch", ["req": 2, "id": "x"]))
        try await expectBool("mac.result", "ok", false)
    }
}
