import XCTest
import SwiftUI
import AppKit
import AVFoundation
@testable import Mydroid
@testable import MydroidCore
@testable import MydroidNM

/// The extension setup model and sheet, the stable folder, the hello that finishes setup, the mirrored preview, and the renders
/// of everything in this round (light and dark). Renders only run when MYDROID_RENDER_DIR is set. Every home is a temporary folder.
@MainActor
final class SetupFlowTests: XCTestCase {
    private var dir: String? { ProcessInfo.processInfo.environment["MYDROID_RENDER_DIR"] }

    private func bundledExtension() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("extension", isDirectory: true)
    }

    /// An installer on a temporary home, with a helper that "exists" and the real extension copied to its stable folder.
    private func installer(helper: Bool = true) throws -> ExtensionInstaller {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-setup-\(UUID().uuidString)", isDirectory: true)
        let host = home.appendingPathComponent("Mydroid.app/Contents/MacOS/mydroid-nmhost")
        try FileManager.default.createDirectory(at: host.deletingLastPathComponent(), withIntermediateDirectories: true)
        if helper { FileManager.default.createFile(atPath: host.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]) }
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return ExtensionInstaller(home: home, hostPath: host.path, extensionFolder: bundledExtension(),
                                  applicationDirectories: [home.appendingPathComponent("Applications")],
                                  defaults: UserDefaults(suiteName: "mydroid.setup.\(UUID().uuidString)")!)
    }

    // MARK: Logic

    func testInstallerCopiesTheExtensionToTheStableFolderAtStart() throws {
        let inst = try installer()
        XCTAssertEqual(inst.extensionFolder, inst.stableFolder)
        XCTAssertTrue(inst.stableFolder.path.hasSuffix("Library/Application Support/Mydroid/Browser Extension"))
        XCTAssertNotNil(ExtensionFolder.version(in: inst.stableFolder))
        XCTAssertFalse(inst.stableFolder.path.contains("Mydroid.app"))
    }

    func testStepsAdvanceAndTheHelloFinishesSetup() async throws {
        let inst = try installer()
        let s = ExtensionSetupModel(browser: .chrome, installer: inst)
        var copied: [String] = []
        s.copy = { copied.append($0) }
        XCTAssertEqual(s.current, .connect)
        s.start()
        XCTAssertEqual(s.current, .openPage)                      // step 1 happened by itself
        XCTAssertEqual(inst.row(.chrome).state, .installed)
        XCTAssertTrue(s.developerInstallAvailable)
        XCTAssertFalse(s.developerInstall)
        s.chooseDeveloperInstall(true)
        XCTAssertTrue(s.developerInstall)
        s.fixture(step: .devMode)                                  // as if the page was opened
        XCTAssertEqual(s.current, .devMode)
        s.devModeOn()
        XCTAssertEqual(s.current, .add)
        XCTAssertFalse(s.ready)
        s.copyPath()
        XCTAssertEqual(copied, [inst.stableFolder.path])
        // The extension starts in Chrome and says hello.
        inst.markSeen(.chrome)
        XCTAssertTrue(s.ready)
        XCTAssertEqual(s.current, .done)
        XCTAssertTrue(inst.row(.chrome).ready)
        XCTAssertFalse(inst.row(.edge).ready)
    }

    func testHelloFromTheOtherBrowserDoesNotFinishThisSetup() throws {
        let inst = try installer()
        let s = ExtensionSetupModel(browser: .chrome, installer: inst)
        s.start()
        inst.markSeen(.arc)
        XCTAssertFalse(s.ready)
    }

    func testHelloWithoutTheConnectionIsNotReady() throws {
        let inst = try installer()
        inst.markSeen(.brave)                                      // seen, but the host manifest isn't there
        XCTAssertFalse(inst.row(.brave).ready)
    }

    func testSetUpAgainWaitsForANewHello() throws {
        let inst = try installer()
        inst.install(.chrome)
        inst.markSeen(.chrome, at: Date().addingTimeInterval(-3600))
        let s = ExtensionSetupModel(browser: .chrome, installer: inst)
        XCTAssertTrue(s.ready)                                     // opens straight on "ready"
        s.setUpAgain()
        XCTAssertFalse(s.ready)
        XCTAssertEqual(s.current, .openPage)
        inst.markSeen(.chrome)
        XCTAssertTrue(s.ready)
    }

    func testSeenSurvivesRelaunchAndRemoveForgets() throws {
        let inst = try installer()
        inst.install(.edge); inst.markSeen(.edge)
        let again = ExtensionInstaller(home: inst.home, hostPath: inst.hostPath, extensionFolder: nil,
                                       applicationDirectories: [], defaults: inst.defaults)
        XCTAssertTrue(again.row(.edge).ready)
        again.remove(.edge)
        XCTAssertFalse(again.row(.edge).ready)
    }

    func testRelaunchUpdatesAnExistingDeveloperOnlyManifest() throws {
        let inst = try installer()
        inst.install(.chrome)
        inst.markSeen(.chrome)
        let file = ChromiumBrowser.chrome.manifestURL(home: inst.home)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        manifest["allowed_origins"] = ["chrome-extension://\(NativeMessaging.extensionID)/"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: file)
        XCTAssertEqual(ManifestInstaller.state(.chrome, home: inst.home, hostPath: inst.hostPath), .outdated)

        let again = ExtensionInstaller(home: inst.home, hostPath: inst.hostPath, extensionFolder: nil,
                                       applicationDirectories: [], defaults: inst.defaults)
        XCTAssertTrue(again.row(.chrome).ready)
        XCTAssertEqual(again.row(.edge).state, .notInstalled)
    }

    func testTheHelloFromTheSocketReachesTheInstaller() async throws {
        let m = AppModel(fixture: HubState())
        _ = await OTPBridge(broker: m.hub.auth, host: m.otpService).handle(["op": "hello", "browser": "Chrome", "parent": "/Applications/Arc.app/Contents/MacOS/Arc"])
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNotNil(m.extensionInstaller.seenAt["arc"])        // the parent program wins over the extension's own name
        XCTAssertNil(m.extensionInstaller.seenAt["chrome"])
    }

    func testNoHelperMeansStepOneCannotRun() throws {
        let inst = try installer(helper: false)
        let s = ExtensionSetupModel(browser: .chrome, installer: inst)
        s.start()
        XCTAssertEqual(s.current, .connect)
        XCTAssertFalse(s.helperAvailable)
    }

    // MARK: The preview is a mirror; detection still reads raw frames

    func testPreviewIsMirroredAndDetectionStillReadsTheRawImage() throws {
        XCTAssertTrue(CameraImportView.mirrorsPreview)
        let img = try XCTUnwrap(QRImage.make(MigrationFixture.uri(size: 3, index: 1, id: 9, accounts: 4)))
        XCTAssertEqual(QRDetector.payloads(in: img).count, 1)       // the unmirrored frame the camera hands Vision
    }

    func testPreviewViewMirrorsWithoutAConnectionWithoutCrashing() {
        let v = CameraPreview.PreviewView()
        v.applyMirror()                                             // no session yet: nothing to flip, nothing breaks
        XCTAssertNil(v.previewLayer.connection)
    }

    // MARK: Renders

    private func write<V: View>(_ name: String, _ scheme: ColorScheme, size: CGSize, _ content: V) throws {
        guard let dir else { throw XCTSkip("MYDROID_RENDER_DIR not set") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
        var size = size
        if size.height == 0 { size.height = host.fittingSize.height }
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

    func testRenderSetupSheet() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        for scheme in [ColorScheme.light, .dark] {
            func sheet(_ step: ExtensionSetupModel.Step, fallback: Bool = false, helper: Bool = true,
                       browser: ChromiumBrowser = .chrome, developerInstall: Bool = true) throws -> some View {
                let inst = try installer(helper: helper)
                let s = ExtensionSetupModel(browser: browser, installer: inst)
                if step > .connect { inst.install(browser) }
                s.fixture(step: step, fallback: fallback, developerInstall: developerInstall)
                if step == .done { inst.markSeen(browser) }
                return ExtensionSetupSheet(setup: s).environment(\.colorScheme, scheme)
            }
            try write("setup-1-connect", scheme, size: CGSize(width: 480, height: 0), try sheet(.connect, helper: false))
            try write("setup-install-options", scheme, size: CGSize(width: 480, height: 0), try sheet(.openPage, developerInstall: false))
            try write("setup-2-open", scheme, size: CGSize(width: 480, height: 0), try sheet(.openPage))
            try write("setup-3-developer-mode", scheme, size: CGSize(width: 480, height: 0), try sheet(.devMode))
            try write("setup-3b-after-fallback", scheme, size: CGSize(width: 480, height: 0), try sheet(.devMode, fallback: true))
            try write("setup-4-add", scheme, size: CGSize(width: 480, height: 0), try sheet(.add))
            try write("setup-4b-add-fallback", scheme, size: CGSize(width: 480, height: 0), try sheet(.add, fallback: true, browser: .arc))
            try write("setup-5-done", scheme, size: CGSize(width: 480, height: 0), try sheet(.done))
        }
    }

    func testRenderSettingsAuthenticatorBrowsers() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        var st = HubState(); st.link = .connected
        st.phone = PhoneInfo(name: "Pixel 9", model: "Pixel 9", battery: 78, charging: false, network: .wifi)
        let m = AppModel(fixture: st)
        m.extensionInstaller.install(.chrome); m.extensionInstaller.markSeen(.chrome)   // Ready
        m.extensionInstaller.install(.edge)                                             // connected, extension not loaded yet
        for scheme in [ColorScheme.light, .dark] {
            try write("settings-authenticator-browsers", scheme, size: CGSize(width: 740, height: 760),
                      SettingsView(initial: .authenticator, height: 760).environment(m))
        }
    }

    func testRenderPopoverHeaderAndFooter() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        for (name, link) in [("connected", LinkState.connected), ("searching", .searching)] {
            var st = HubState(); st.link = link
            st.phone = PhoneInfo(name: "Pixel 9", model: "Pixel 9", battery: 78, charging: false, network: .wifi)
            let m = AppModel(fixture: st)
            for scheme in [ColorScheme.light, .dark] {
                let v = VStack(spacing: 0) { HeaderView(); Divider().opacity(0.5); FooterView() }.frame(width: 372)
                try write("popover-header-gear-\(name)", scheme, size: CGSize(width: 372, height: 130), v.environment(m).environment(\.colorScheme, scheme))
            }
        }
    }
}
