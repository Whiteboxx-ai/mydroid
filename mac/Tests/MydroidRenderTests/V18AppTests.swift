import XCTest
import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
@testable import Mydroid
@testable import MydroidCore

// v1.8 on the Mac side. No camera is turned on, nothing is sent to a phone, and Spotify is never touched: everything goes through fakes.

/// A camera that is never on. `emit` plays frames in.
@MainActor
final class FakeCamera: CameraSource {
    var current = CameraAccess.authorized
    var grantOnRequest = true
    var hasDevice = true
    private(set) var running = false
    private(set) var starts = 0
    private(set) var stops = 0
    var stillPreview: NSImage?
    private var handler: (@MainActor ([String]) -> Void)?

    func access() -> CameraAccess { current }
    func requestAccess() async -> Bool { current = grantOnRequest ? .authorized : .denied; return grantOnRequest }
    func start(onPayloads: @escaping @MainActor ([String]) -> Void) -> Bool {
        guard hasDevice else { return false }
        handler = onPayloads; running = true; starts += 1
        return true
    }
    func stop() { running = false; handler = nil; stops += 1 }
    func emit(_ payloads: [String]) { handler?(payloads) }
}

/// An importer that records what it was given and answers as told.
final class RecordingImporter: AuthImporting, @unchecked Sendable {
    private let lock = NSLock()
    private var _received: [[String]] = []
    var outcome: AuthImportOutcome = .added(added: 0, skipped: 0)
    var delay: Duration = .zero
    var received: [[String]] { lock.lock(); defer { lock.unlock() }; return _received }
    private func record(_ u: [String]) { lock.lock(); _received.append(u); lock.unlock() }
    func importAccounts(uris: [String]) async -> AuthImportOutcome {
        record(uris)
        if delay > .zero { try? await Task.sleep(for: delay) }
        return outcome
    }
}

/// An app that records instead of playing.
@MainActor
final class RecordingSpotify: SpotifyPlaying {
    var isInstalled = true
    var result = SpotifyResult.ok
    private(set) var scripts: [String] = []
    func play(script: String) async -> SpotifyResult { scripts.append(script); return result }
}

/// Synthetic `otpauth-migration://` URIs in Google Authenticator's wire format (the Core tests have their own copy).
enum MigrationFixture {
    static func uri(size: Int, index: Int, id: Int64, accounts: Int = 2) -> String {
        var w = PBWriter()
        for n in 0..<accounts {
            var p = PBWriter()
            p.bytes(1, Data((0..<10).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ n) }))
            p.string(2, "user\(n)@example.com"); p.string(3, "Issuer\(n)")
            p.varint(4, 1); p.varint(5, 1); p.varint(6, 2)
            w.message(1, p.data)
        }
        w.int(2, 1); w.int(3, Int64(size)); w.int(4, Int64(index)); w.int(5, id)
        let b64 = w.data.base64EncodedString()
        return "otpauth-migration://offline?data=" + b64.replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "/", with: "%2F").replacingOccurrences(of: "=", with: "%3D")
    }
    static let single = "otpauth://totp/Example:me@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example"
}

enum QRImage {
    /// A QR code as a crisp, padded image, the way a camera would see a screen showing it.
    static func make(_ text: String, scale: CGFloat = 8) -> CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "L"
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let pad = 4 * scale
        let canvas = scaled.extent.insetBy(dx: -pad, dy: -pad)
        let white = CIImage(color: .white).cropped(to: canvas)
        let composed = scaled.composited(over: white)
        return CIContext().createCGImage(composed, from: canvas)
    }
}

@MainActor
final class QRDetectorTests: XCTestCase {
    func testReadsASingleOtpauthCode() throws {
        let img = try XCTUnwrap(QRImage.make(MigrationFixture.single))
        XCTAssertEqual(QRDetector.payloads(in: img), [MigrationFixture.single])
    }

    func testReadsAMigrationCodeWithManyAccounts() throws {
        let uri = MigrationFixture.uri(size: 3, index: 1, id: 424_242, accounts: 10)
        let img = try XCTUnwrap(QRImage.make(uri))
        let found = QRDetector.payloads(in: img)
        XCTAssertEqual(found, [uri])
        guard case .migration(let info) = ScanPayload.classify(found[0]) else { return XCTFail("not a migration code") }
        XCTAssertEqual(info.batchSize, 3); XCTAssertEqual(info.batchIndex, 1); XCTAssertEqual(info.accountCount, 10)
    }

    func testAPictureWithoutACodeFindsNothing() throws {
        let f = CIFilter.randomGenerator()
        let img = CIContext().createCGImage(try XCTUnwrap(f.outputImage).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300)), from: CGRect(x: 0, y: 0, width: 400, height: 300))!
        XCTAssertTrue(QRDetector.payloads(in: img).isEmpty)
    }

    func testOtherCodesAreReadButNeverTaken() throws {
        let img = try XCTUnwrap(QRImage.make("https://example.com/menu"))
        let found = QRDetector.payloads(in: img)
        XCTAssertEqual(found, ["https://example.com/menu"])
        var t = ImportTracker()
        XCTAssertEqual(t.ingest(found[0]), .notForUs)
    }

    /// Three parts shown in turn, each seen in many frames, through the real detector and the tracker.
    func testAWholeExportThroughTheDetector() throws {
        let parts = (0..<3).map { MigrationFixture.uri(size: 3, index: $0, id: 31_337, accounts: 6) }
        let images = try parts.map { try XCTUnwrap(QRImage.make($0)) }
        var t = ImportTracker()
        var events: [ImportTracker.Event] = []
        outer: for (i, img) in images.enumerated() {
            for _ in 0..<5 {
                for p in QRDetector.payloads(in: img) {
                    events.append(t.ingest(p))
                    if case .complete = events.last! { break outer }      // the controller stops reading here
                }
            }
            XCTAssertEqual(t.scanned, i + 1)
        }
        XCTAssertEqual(events.filter { $0 == .duplicate }.count, 8, "four repeat frames for each of the first two parts")
        XCTAssertEqual(events.last, .complete(parts))
    }
}

@MainActor
final class CameraImportControllerTests: XCTestCase {
    let a = MigrationFixture.uri(size: 3, index: 0, id: 100)
    let b = MigrationFixture.uri(size: 3, index: 1, id: 100)
    let c = MigrationFixture.uri(size: 3, index: 2, id: 100)

    func make(camera: FakeCamera? = nil, connected: Bool = true) -> (CameraImportController, FakeCamera, RecordingImporter) {
        let camera = camera ?? FakeCamera()
        let imp = RecordingImporter()
        return (CameraImportController(camera: camera, importer: imp, phoneConnected: connected), camera, imp)
    }

    func settle() async { for _ in 0..<20 { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) } }

    func testScansThreePartsThenSendsAndStopsTheCamera() async {
        let (ctl, cam, imp) = make()
        imp.outcome = .added(added: 12, skipped: 2)
        ctl.begin()
        XCTAssertEqual(ctl.phase, .scanning); XCTAssertTrue(cam.running); XCTAssertNil(ctl.progress)
        cam.emit([b]); XCTAssertEqual(ctl.progress?.scanned, 1); XCTAssertEqual(ctl.progress?.total, 3)
        cam.emit([b, b]); XCTAssertEqual(ctl.progress?.scanned, 1, "repeated frames of one code")
        cam.emit([c, a]); XCTAssertEqual(ctl.phase, .approving)
        XCTAssertFalse(cam.running, "camera off the moment the batch is whole")
        await settle()
        XCTAssertEqual(imp.received, [[a, b, c]])
        XCTAssertEqual(ctl.phase, .done(added: 12, skipped: 2))
    }

    func testNothingIsSentMidBatch() {
        let (ctl, cam, imp) = make()
        ctl.begin()
        cam.emit([a]); cam.emit([b])
        XCTAssertEqual(ctl.progress?.scanned, 2)
        XCTAssertEqual(ctl.phase, .scanning)
        XCTAssertTrue(imp.received.isEmpty)
    }

    func testASingleCodeSendsAtOnce() async {
        let (ctl, cam, imp) = make()
        imp.outcome = .added(added: 1, skipped: 0)
        ctl.begin()
        cam.emit([MigrationFixture.single])
        await settle()
        XCTAssertEqual(imp.received, [[MigrationFixture.single]])
        XCTAssertEqual(ctl.phase, .done(added: 1, skipped: 0))
        XCTAssertFalse(cam.running)
    }

    func testOtherCodesGetAGentleHintAndScanningContinues() {
        let (ctl, cam, imp) = make()
        ctl.begin()
        cam.emit(["https://example.com"])
        XCTAssertNotNil(ctl.hint)
        XCTAssertEqual(ctl.phase, .scanning); XCTAssertTrue(cam.running)
        XCTAssertTrue(imp.received.isEmpty)
        cam.emit([a]); XCTAssertNil(ctl.hint, "progress clears the hint")
    }

    func testMoreCodesAfterSendingAreIgnored() async {
        let (ctl, cam, imp) = make()
        imp.delay = .milliseconds(100)
        ctl.begin()
        cam.emit([MigrationFixture.single])
        XCTAssertEqual(ctl.phase, .approving)
        cam.emit([MigrationFixture.single]); ctl.ingest([MigrationFixture.single])
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(imp.received.count, 1)
    }

    func testPhoneAnswersMapToFriendlyFailures() async {
        for (outcome, failure) in [(AuthImportOutcome.cancelled, ImportFailure.cancelled), (.locked, .locked), (.invalid, .invalid),
                                   (.offline, .offline), (.timeout, .timeout), (.failed, .other)] {
            let (ctl, cam, imp) = make()
            imp.outcome = outcome
            ctl.begin(); cam.emit([MigrationFixture.single])
            await settle()
            XCTAssertEqual(ctl.phase, .failed(failure), "\(outcome)")
            XCTAssertFalse(failure.title.isEmpty); XCTAssertFalse(failure.detail.isEmpty)
        }
    }

    func testScanAgainStartsClean() async {
        let (ctl, cam, imp) = make()
        imp.outcome = .cancelled
        ctl.begin(); cam.emit([MigrationFixture.single]); await settle()
        XCTAssertEqual(ctl.phase, .failed(.cancelled))
        ctl.begin()
        XCTAssertEqual(ctl.phase, .scanning); XCTAssertTrue(cam.running); XCTAssertNil(ctl.progress); XCTAssertEqual(cam.starts, 2)
    }

    func testClosingTheWindowStopsTheCameraAndForgets() async {
        let (ctl, cam, imp) = make()
        ctl.begin(); cam.emit([a, b])
        ctl.stop()
        XCTAssertFalse(cam.running); XCTAssertNil(ctl.progress)
        ctl.ingest([c])
        XCTAssertTrue(imp.received.isEmpty)
        // And a late answer after closing changes nothing.
        let (ctl2, cam2, imp2) = make()
        imp2.delay = .milliseconds(80)
        ctl2.begin(); cam2.emit([MigrationFixture.single])
        ctl2.stop()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(ctl2.phase, .approving, "no result is shown for a closed window")
    }

    func testCameraPermission() async {
        let cam = FakeCamera(); cam.current = .notDetermined
        let (ctl, _, _) = make(camera: cam)
        ctl.begin()
        XCTAssertEqual(ctl.phase, .askingForCamera); XCTAssertFalse(cam.running)
        await settle()
        XCTAssertEqual(ctl.phase, .scanning); XCTAssertTrue(cam.running)

        let denied = FakeCamera(); denied.current = .denied
        let (ctl2, _, _) = make(camera: denied)
        ctl2.begin()
        XCTAssertEqual(ctl2.phase, .cameraDenied); XCTAssertEqual(denied.starts, 0)

        let refuse = FakeCamera(); refuse.current = .notDetermined; refuse.grantOnRequest = false
        let (ctl3, _, _) = make(camera: refuse)
        ctl3.begin(); await settle()
        XCTAssertEqual(ctl3.phase, .cameraDenied); XCTAssertEqual(refuse.starts, 0)

        let none = FakeCamera(); none.hasDevice = false
        let (ctl4, _, _) = make(camera: none)
        ctl4.begin()
        XCTAssertEqual(ctl4.phase, .noCamera)
    }

    func testNoPhoneNoCameraUntilItConnects() {
        let (ctl, cam, _) = make(connected: false)
        ctl.begin()
        XCTAssertEqual(ctl.phase, .offline); XCTAssertEqual(cam.starts, 0)
        ctl.phoneConnection(true)
        XCTAssertEqual(ctl.phase, .scanning); XCTAssertTrue(cam.running)
        cam.emit([a])
        ctl.phoneConnection(false)
        XCTAssertEqual(ctl.phase, .offline); XCTAssertFalse(cam.running); XCTAssertNil(ctl.progress)
    }

    func testCopy() {
        XCTAssertEqual(CameraImportView.doneTitle(added: 12, skipped: 0), "Added 12 accounts on your phone")
        XCTAssertEqual(CameraImportView.doneTitle(added: 1, skipped: 0), "Added 1 account on your phone")
        XCTAssertEqual(CameraImportView.doneTitle(added: 0, skipped: 3), "Already on your phone")
        XCTAssertTrue(CameraImportView.doneDetail(added: 5, skipped: 0).hasPrefix("Nothing was saved on this Mac."))
        XCTAssertTrue(CameraImportView.doneDetail(added: 5, skipped: 2).contains("2 were already there"))
    }
}

@MainActor
final class MediaHandoffTests: XCTestCase {
    let id = "4uLU6hMCjMI75M1A2tKUQC"
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    final class Probe { var paused = 0; var explained = 0; var marked = 0; var accept = true }

    func media(id: String?, playing: Bool = true) -> MediaState {
        MediaState(title: "Blinding Lights", artist: "The Weeknd", playing: playing, position: 60_000, duration: 200_000, ts: t0, mediaId: id)
    }

    func handoff(_ spotify: RecordingSpotify, _ opener: RecordingOpener, _ p: Probe, pause: Bool = true, explained: Bool = true) -> MediaHandoff {
        MediaHandoff(spotify: spotify, opener: opener, pausePhone: pause, explained: explained,
                     markExplained: { p.marked += 1 }, explain: { p.explained += 1; return p.accept }, sendPause: { p.paused += 1 },
                     now: { self.t0.addingTimeInterval(10) })
    }

    func testPlaysInSpotifyFromTheExtrapolatedPositionThenPausesThePhone() async throws {
        let (sp, op, p) = (RecordingSpotify(), RecordingOpener(), Probe())
        let r = await handoff(sp, op, p).run(media(id: "spotify:track:\(id)"))
        XCTAssertEqual(r, .playingInSpotify)
        let script = try XCTUnwrap(sp.scripts.first)
        XCTAssertTrue(script.contains("play track \"spotify:track:\(id)\""))
        XCTAssertTrue(script.contains("set player position to 70.0"), "60 s sampled 10 s ago while playing")
        XCTAssertTrue(op.opened.isEmpty)
        XCTAssertEqual(p.paused, 1)
        XCTAssertEqual(p.explained, 0)
    }

    func testPausedTrackStartsWhereItWasPaused() async throws {
        let (sp, op, p) = (RecordingSpotify(), RecordingOpener(), Probe())
        _ = await handoff(sp, op, p).run(media(id: "spotify:track:\(id)", playing: false))
        XCTAssertTrue(try XCTUnwrap(sp.scripts.first).contains("set player position to 60.0"))
    }

    func testWithoutSpotifyOpensTheWebPlayerAndPauses() async {
        let sp = RecordingSpotify(); sp.isInstalled = false
        let (op, p) = (RecordingOpener(), Probe())
        let r = await handoff(sp, op, p).run(media(id: "spotify:episode:\(id)"))
        XCTAssertEqual(r, .openedInBrowser(why: nil))
        XCTAssertEqual(op.opened.map(\.url.absoluteString), ["https://open.spotify.com/episode/\(id)"])
        XCTAssertTrue(sp.scripts.isEmpty)
        XCTAssertEqual(p.paused, 1)
    }

    func testPhonePauseCanBeTurnedOff() async {
        let sp = RecordingSpotify()
        let (op, p) = (RecordingOpener(), Probe())
        _ = await handoff(sp, op, p, pause: false).run(media(id: "spotify:track:\(id)"))
        XCTAssertEqual(p.paused, 0)
        sp.isInstalled = false
        _ = await handoff(sp, op, p, pause: false).run(media(id: "spotify:track:\(id)"))
        XCTAssertEqual(p.paused, 0)
    }

    func testFirstTimeExplainsAutomationOnce() async {
        let (sp, op, p) = (RecordingSpotify(), RecordingOpener(), Probe())
        let r = await handoff(sp, op, p, explained: false).run(media(id: "spotify:track:\(id)"))
        XCTAssertEqual(r, .playingInSpotify)
        XCTAssertEqual(p.explained, 1); XCTAssertEqual(p.marked, 1)
    }

    func testDecliningTheExplainerUsesTheBrowserAndIsNotRemembered() async {
        let (sp, op, p) = (RecordingSpotify(), RecordingOpener(), Probe())
        p.accept = false
        let r = await handoff(sp, op, p, explained: false).run(media(id: "spotify:track:\(id)"))
        XCTAssertEqual(r, .openedInBrowser(why: .declined))
        XCTAssertTrue(sp.scripts.isEmpty); XCTAssertEqual(p.marked, 0)
        XCTAssertEqual(op.opened.count, 1)
        XCTAssertEqual(p.paused, 1)
    }

    func testAutomationRefusedFallsBackToTheBrowserAndSaysWhy() async {
        let (sp, op, p) = (RecordingSpotify(), RecordingOpener(), Probe())
        sp.result = .notAllowed
        let r = await handoff(sp, op, p).run(media(id: "spotify:track:\(id)"))
        XCTAssertEqual(r, .openedInBrowser(why: .spotifyNotAllowed))
        XCTAssertTrue(r.message.contains("Automation"))
        XCTAssertEqual(op.opened.count, 1)
        sp.result = .failed
        let r2 = await handoff(sp, op, p).run(media(id: "spotify:track:\(id)"))
        XCTAssertEqual(r2, .openedInBrowser(why: .spotifyFailed))
    }

    func testNothingOpenedMeansNoPause() async {
        let sp = RecordingSpotify(); sp.isInstalled = false
        let (op, p) = (RecordingOpener(), Probe())
        op.failWeb = true
        let r = await handoff(sp, op, p).run(media(id: "spotify:track:\(id)"))
        XCTAssertEqual(r, .failed)
        XCTAssertEqual(p.paused, 0, "the song is still on the phone, so keep it playing")
    }

    func testOtherLinksJustOpen() async {
        let (sp, op, p) = (RecordingSpotify(), RecordingOpener(), Probe())
        let r = await handoff(sp, op, p).run(media(id: "https://music.example.com/watch?v=1"))
        XCTAssertEqual(r, .openedInBrowser(why: nil))
        XCTAssertEqual(op.opened.first?.url.absoluteString, "https://music.example.com/watch?v=1")
        XCTAssertTrue(sp.scripts.isEmpty)
    }

    func testWithoutAMediaIdItSearchesAndLeavesThePhoneAlone() async {
        let (sp, op, p) = (RecordingSpotify(), RecordingOpener(), Probe())
        let r = await handoff(sp, op, p).run(media(id: nil))
        XCTAssertEqual(r, .searched)
        XCTAssertEqual(op.opened.first?.url.absoluteString, "https://www.google.com/search?q=Blinding%20Lights%20The%20Weeknd")
        XCTAssertTrue(sp.scripts.isEmpty)
        XCTAssertEqual(p.paused, 0)
    }

    func testToastsNeverNameTheSong() {
        for r in [HandoffResult.playingInSpotify, .openedInBrowser(why: nil), .openedInBrowser(why: .declined), .openedInBrowser(why: .spotifyFailed),
                  .openedInBrowser(why: .spotifyNotAllowed), .searched, .failed] {
            XCTAssertFalse(r.message.contains("Blinding")); XCTAssertFalse(r.message.contains("spotify:"))
        }
    }

    func testThroughTheAppModelAndItsPreferences() async {
        let model = AppModel(fixture: HubState())
        let (sp, op) = (RecordingSpotify(), RecordingOpener())
        model.spotify = sp; model.opener = op; model.explainSpotify = { true }
        XCTAssertTrue(model.prefs.pausePhoneOnContinue, "on by default")
        XCTAssertFalse(model.prefs.spotifyAutomationExplained)
        model.continueOnMac(media(id: "spotify:track:\(id)"))
        for _ in 0..<40 where model.toast == nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.toast, HandoffResult.playingInSpotify.message)
        XCTAssertEqual(sp.scripts.count, 1)
        XCTAssertTrue(model.prefs.spotifyAutomationExplained, "remembered after the first time")
    }

    func testPreferencesDecodeFromOlderBuilds() throws {
        let old = try JSONDecoder().decode(MacPrefs.self, from: Data(#"{"showBatteryInMenuBar":true}"#.utf8))
        XCTAssertTrue(old.pausePhoneOnContinue); XCTAssertFalse(old.spotifyAutomationExplained)
        var p = MacPrefs(); p.pausePhoneOnContinue = false
        let back = try JSONDecoder().decode(MacPrefs.self, from: JSONEncoder().encode(p))
        XCTAssertFalse(back.pausePhoneOnContinue)
    }
}
