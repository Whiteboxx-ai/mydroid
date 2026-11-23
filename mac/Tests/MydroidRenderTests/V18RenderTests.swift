import XCTest
import SwiftUI
import AppKit
import CoreImage
@testable import Mydroid
@testable import MydroidCore

/// Off-screen renders of the camera import window and the Now Playing row (light and dark). Only runs when MYDROID_RENDER_DIR is set.
/// No camera is on: the preview is a drawn still of a phone showing a QR code.
@MainActor
final class V18RenderTests: XCTestCase {
    private var dir: String? { ProcessInfo.processInfo.environment["MYDROID_RENDER_DIR"] }

    private func write<V: View>(_ name: String, _ scheme: ColorScheme, width: CGFloat, height: CGFloat? = nil, _ content: V) throws {
        guard let dir else { throw XCTSkip("MYDROID_RENDER_DIR not set") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: content)
        let fit = host.fittingSize
        let size = CGSize(width: width, height: height ?? max(fit.height, 60))
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        win.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap for \(name)") }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("png failed for \(name)") }
        try png.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }

    /// A webcam-ish still: a dim room and a phone showing a transfer QR code.
    private func stillFrame() -> NSImage {
        let size = NSSize(width: 864, height: 580)
        let img = NSImage(size: size)
        img.lockFocus()
        NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.23, blue: 0.28, alpha: 1), NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: size), angle: -60)
        let phone = NSRect(x: 252, y: 40, width: 360, height: 500)
        NSColor(calibratedWhite: 0.05, alpha: 1).setFill()
        NSBezierPath(roundedRect: phone, xRadius: 40, yRadius: 40).fill()
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSBezierPath(roundedRect: phone.insetBy(dx: 14, dy: 14), xRadius: 28, yRadius: 28).fill()
        if let qr = QRImage.make(MigrationFixture.uri(size: 3, index: 1, id: 1, accounts: 6), scale: 4) {
            NSImage(cgImage: qr, size: NSSize(width: 300, height: 300)).draw(in: NSRect(x: 282, y: 140, width: 300, height: 300))
        }
        img.unlockFocus()
        return img
    }

    private func controller(connected: Bool = true) -> CameraImportController {
        let cam = FakeCamera()
        cam.stillPreview = stillFrame()
        return CameraImportController(camera: cam, importer: RecordingImporter(), phoneConnected: connected)
    }

    func testImportWindow() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let cases: [(String, ImportPhase, (Int, Int)?, String?)] = [
            ("import-1-guide", .scanning, nil, nil),
            ("import-2-progress", .scanning, (2, 3), nil),
            ("import-2b-hint", .scanning, (1, 3), "Not a Google Authenticator transfer code"),
            ("import-3-approve", .approving, (3, 3), nil),
            ("import-4-success", .done(added: 12, skipped: 2), (3, 3), nil),
            ("import-5-error-cancelled", .failed(.cancelled), nil, nil),
            ("import-5b-error-locked", .failed(.locked), nil, nil),
            ("import-6-offline", .offline, nil, nil),
            ("import-7-camera-denied", .cameraDenied, nil, nil),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, phase, progress, hint) in cases {
                let c = controller(connected: phase != .offline)
                c.fixture(phase: phase, progress: progress, hint: hint)
                try write(name, scheme, width: CameraImportView.width, CameraImportView(controller: c).environment(\.colorScheme, scheme))
            }
        }
    }

    // MARK: Now Playing

    private func media(id: String?) -> MediaState {
        MediaState(pkg: "com.spotify.music", app: "Spotify", title: "Blinding Lights", artist: "The Weeknd", album: "After Hours",
                   playing: true, position: 83_000, duration: 200_000, ts: Date(), canSeek: true, canNext: true, canPrev: true, mediaId: id)
    }

    func testNowPlayingRow() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        for scheme in [ColorScheme.light, .dark] {
            let bg = scheme == .dark ? Color(white: 0.16) : Color(white: 0.96)
            func frame<V: View>(_ v: V) -> some View { v.padding(12).frame(width: 372).background(bg).environment(\.colorScheme, scheme) }
            try write("nowplaying-continue", scheme, width: 372, frame(NowPlayingRow(media: media(id: "spotify:track:4uLU6hMCjMI75M1A2tKUQC"), command: { _ in }, handoff: {})))
            try write("nowplaying-search", scheme, width: 372, frame(NowPlayingRow(media: media(id: nil), command: { _ in }, handoff: {})))
            try write("nowplaying-none", scheme, width: 372, frame(NowPlayingRow(media: media(id: nil), command: { _ in }, handoff: nil)))
        }
    }

    func testMediaSettings() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        var st = HubState(); st.link = .connected
        st.phone = PhoneInfo(name: "Pixel 9", model: "Pixel 9", battery: 78, charging: false, network: .wifi)
        let m = AppModel(fixture: st)
        for s in [ColorScheme.light, .dark] {
            try write("settings-media", s, width: 740, height: 560, SettingsView(initial: .media, height: 560).environment(m))
            try write("settings-auth-import", s, width: 740, height: 900, SettingsView(initial: .authenticator, height: 900).environment(m))
        }
    }
}
