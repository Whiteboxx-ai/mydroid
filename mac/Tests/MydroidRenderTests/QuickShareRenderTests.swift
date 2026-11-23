import XCTest
import SwiftUI
import AppKit
@testable import Mydroid
@testable import MydroidCore

/// Off-screen renders of the Quick Share banners and the Quick Share and Files settings. Only runs when MYDROID_RENDER_DIR is set;
/// nothing is shown on screen.
@MainActor
final class QuickShareRenderTests: XCTestCase {
    private var dir: String? { ProcessInfo.processInfo.environment["MYDROID_RENDER_DIR"] }

    private func state() -> HubState {
        var st = HubState()
        st.link = .connected
        st.phone = PhoneInfo(name: "Pixel 9", model: "Pixel 9", battery: 78, charging: false, network: .wifi)
        return st
    }

    private func write(_ rep: NSBitmapImageRep, _ name: String, _ scheme: ColorScheme) throws {
        guard let dir else { throw XCTSkip("MYDROID_RENDER_DIR not set") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("png failed for \(name)") }
        try png.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }

    /// A banner on a plain backdrop, like the other banner renders.
    private func banner(_ name: String, _ scheme: ColorScheme, _ item: BannerItem) throws {
        guard dir != nil else { throw XCTSkip("MYDROID_RENDER_DIR not set") }
        let ui = NotifUIState()
        let view = BannerView(item: item, onClose: {}, onDismiss: {}).environment(ui).padding(.vertical, 4)
            .environment(\.colorScheme, scheme)
            .frame(width: 384)
            .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let tiff = r.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return XCTFail("render failed for \(name)") }
        try write(rep, name, scheme)
    }

    private func window<V: View>(_ name: String, _ scheme: ColorScheme, size: CGSize, _ content: V) throws {
        guard dir != nil else { throw XCTSkip("MYDROID_RENDER_DIR not set") }
        let host = NSHostingView(rootView: content)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        win.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap for \(name)") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try write(rep, name, scheme)
    }

    private func notification(_ title: String, _ text: String) -> PhoneNotification {
        PhoneNotification(key: "qs", pkg: "mydroid.quickshare", app: "Quick Share", title: title, text: text)
    }

    func testBanners() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let one = QuickShareIncoming(id: "c1", sender: "Dev's Laptop", deviceType: .laptop, pin: "4821", fileCount: 1, linkCount: 0, textCount: 0,
                                     totalBytes: 2_400_000, firstFileName: "Quarterly report final v3.pdf", expires: Date().addingTimeInterval(30))
        let phone = QuickShareIncoming(id: "c2", sender: "Maya's Galaxy S24", deviceType: .phone, pin: "0793", fileCount: 12, linkCount: 0, textCount: 0,
                                       totalBytes: 48_000_000, firstFileName: "IMG_0001.jpg", expires: Date().addingTimeInterval(30))
        let saved1 = QuickShareDone(id: "c3", sender: "Pixel 9", files: [
            SavedFile(xid: "a", kind: "file", url: URL(fileURLWithPath: "/Users/me/Downloads/boarding-pass.pdf"), name: "boarding-pass.pdf", size: 120_000, taken: nil, savedAt: Date())])
        let saved3 = QuickShareDone(id: "c4", sender: "Pixel 9", files: (1...3).map {
            SavedFile(xid: "f\($0)", kind: "file", url: URL(fileURLWithPath: "/Users/me/Downloads/IMG_000\($0).jpg"), name: "IMG_000\($0).jpg", size: 1000, taken: nil, savedAt: Date())})
        for scheme in [ColorScheme.light, .dark] {
            try banner("banner-quickshare-request", scheme, BannerItem(notification("Dev's Laptop", "x"), kind: .quickShareRequest(one)))
            try banner("banner-quickshare-request-phone", scheme, BannerItem(notification("Maya", "x"), kind: .quickShareRequest(phone)))
            try banner("banner-copied-from", scheme, BannerItem(notification("Pixel 9", "x"), kind: .copied(from: "Pixel 9", preview: "Flight BA 142 lands at 18:35, terminal 5. Pick-up at gate B\u{2026}")))
            try banner("banner-quickshare-saved", scheme, BannerItem(notification("Pixel 9", "x"), kind: .saved(saved1)))
            try banner("banner-quickshare-saved-many", scheme, BannerItem(notification("Pixel 9", "x"), kind: .saved(saved3)))
        }
    }

    func testSettings() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let shares = FileShareSettings(roots: [
            FileShareRootSetting(id: "desktop", name: "Desktop", url: home.appendingPathComponent("Desktop")),
            FileShareRootSetting(id: "documents", name: "Documents", url: home.appendingPathComponent("Documents")),
            FileShareRootSetting(id: "downloads", name: "Downloads", url: home.appendingPathComponent("Downloads")),
            FileShareRootSetting(id: "pictures", name: "Pictures", url: home.appendingPathComponent("Pictures"), writable: true),
            FileShareRootSetting(id: "gone", name: "Archive 2019", url: home.appendingPathComponent("Archive 2019")),
        ])
        let model = AppModel(fixture: state(), fileShare: shares)
        model.photosDirectory = home.appendingPathComponent("Pictures/Mydroid")
        let offline = AppModel(fixture: { var s = state(); s.link = .searching; return s }(),
                               prefs: { var p = MacPrefs(); p.quickShare = QuickShareSettings(visibility: .phoneConnected, others: .never, imagesToPhotosFolder: true); return p }(),
                               fileShare: FileShareSettings(enabled: false, roots: Array(shares.roots.prefix(3))))
        offline.photosDirectory = home.appendingPathComponent("Pictures/Mydroid")
        for scheme in [ColorScheme.light, .dark] {
            try window("settings-quickshare-connected", scheme, size: CGSize(width: 740, height: 560), SettingsView(initial: .quickShare).environment(model))
            try window("settings-quickshare-offline", scheme, size: CGSize(width: 740, height: 560), SettingsView(initial: .quickShare).environment(offline))
            try window("settings-files-folders", scheme, size: CGSize(width: 740, height: 780), SettingsView(initial: .files, height: 780).environment(model))
            try window("settings-files-off", scheme, size: CGSize(width: 740, height: 560), SettingsView(initial: .files).environment(offline))
        }
    }
}
