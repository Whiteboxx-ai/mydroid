import XCTest
@testable import MydroidCore
@testable import MydroidNM

/// The stable extension folder, which browser said hello, and the hello op.
final class ExtensionFolderTests: XCTestCase {
    private func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-extfolder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func makeBundle(_ root: URL, version: String, js: String = "// v1") throws -> URL {
        let b = root.appendingPathComponent("bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: b.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b.appendingPathComponent("test"), withIntermediateDirectories: true)
        try Data("{\"version\":\"\(version)\"}".utf8).write(to: b.appendingPathComponent("manifest.json"))
        try Data(js.utf8).write(to: b.appendingPathComponent("background.js"))
        try Data([1, 2, 3]).write(to: b.appendingPathComponent("icons/icon16.png"))
        try Data("x".utf8).write(to: b.appendingPathComponent("test/e2e.mjs"))
        try Data("x".utf8).write(to: b.appendingPathComponent(".DS_Store"))
        return b
    }

    func testStablePathIsUnderApplicationSupport() {
        let home = URL(fileURLWithPath: "/Users/x", isDirectory: true)
        XCTAssertEqual(ExtensionFolder.stableURL(home: home).path, "/Users/x/Library/Application Support/Mydroid/Browser Extension")
    }

    func testVersionComparison() {
        XCTAssertEqual(ExtensionFolder.compare("0.2.0", "0.1.9"), .orderedDescending)
        XCTAssertEqual(ExtensionFolder.compare("0.1", "0.1.0"), .orderedSame)
        XCTAssertEqual(ExtensionFolder.compare("0.9.0", "0.10.0"), .orderedAscending)
    }

    func testFirstCopySkipsTestsAndLitterThenStaysCurrent() throws {
        let root = try temp()
        let b = try makeBundle(root, version: "0.2.0")
        let stable = ExtensionFolder.stableURL(home: root)
        XCTAssertEqual(try ExtensionFolder.sync(bundled: b, stable: stable), .created)
        XCTAssertEqual(ExtensionFolder.version(in: stable), "0.2.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stable.appendingPathComponent("icons/icon16.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stable.appendingPathComponent("test").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stable.appendingPathComponent(".DS_Store").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stable.appendingPathComponent(".mydroid-tmp").path))
        XCTAssertEqual(try ExtensionFolder.sync(bundled: b, stable: stable), .current)
    }

    func testNewerBundledVersionReplacesAndRemovesStaleFiles() throws {
        let root = try temp()
        let stable = ExtensionFolder.stableURL(home: root)
        let old = try makeBundle(root, version: "0.1.0", js: "// old")
        try Data("gone".utf8).write(to: old.appendingPathComponent("stale.js"))
        XCTAssertEqual(try ExtensionFolder.sync(bundled: old, stable: stable), .created)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stable.appendingPathComponent("stale.js").path))
        let new = try makeBundle(root, version: "0.2.0", js: "// new")
        XCTAssertEqual(try ExtensionFolder.sync(bundled: new, stable: stable), .updated)
        XCTAssertEqual(try String(contentsOf: stable.appendingPathComponent("background.js")), "// new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stable.appendingPathComponent("stale.js").path))
    }

    func testOlderBundleNeverDowngradesButSameVersionWithNewFilesRefreshes() throws {
        let root = try temp()
        let stable = ExtensionFolder.stableURL(home: root)
        _ = try ExtensionFolder.sync(bundled: try makeBundle(root, version: "0.3.0", js: "// three"), stable: stable)
        XCTAssertEqual(try ExtensionFolder.sync(bundled: try makeBundle(root, version: "0.2.0", js: "// two"), stable: stable), .current)
        XCTAssertEqual(try String(contentsOf: stable.appendingPathComponent("background.js")), "// three")
        XCTAssertEqual(try ExtensionFolder.sync(bundled: try makeBundle(root, version: "0.3.0", js: "// three, edited"), stable: stable), .updated)
    }

    func testNoBundleIsNotAnError() throws {
        let root = try temp()
        XCTAssertEqual(try ExtensionFolder.sync(bundled: nil, stable: ExtensionFolder.stableURL(home: root)), .noSource)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExtensionFolder.stableURL(home: root).path))
    }

    func testTheShippedExtensionCopiesWithItsManifest() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("extension", isDirectory: true)
        let stable = ExtensionFolder.stableURL(home: try temp())
        XCTAssertEqual(try ExtensionFolder.sync(bundled: src, stable: stable), .created)
        for f in ["manifest.json", "background.js", "content.js", "detector.js", "ui.css", "icons/icon128.png"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: stable.appendingPathComponent(f).path), f)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stable.appendingPathComponent("test").path))
    }
}

final class BrowserDetectionTests: XCTestCase {
    func testParentPathsMapToBrowsers() {
        XCTAssertEqual(ChromiumBrowser.from(executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"), .chrome)
        XCTAssertEqual(ChromiumBrowser.from(executablePath: "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"), .chrome)
        XCTAssertEqual(ChromiumBrowser.from(executablePath: "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"), .edge)
        XCTAssertEqual(ChromiumBrowser.from(executablePath: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"), .brave)
        XCTAssertEqual(ChromiumBrowser.from(executablePath: "/Applications/Arc.app/Contents/MacOS/Arc"), .arc)
        XCTAssertNil(ChromiumBrowser.from(executablePath: "/usr/bin/true"))
    }

    func testExtensionNamesMapToBrowsers() {
        XCTAssertEqual(ChromiumBrowser.from(name: "Chrome"), .chrome)
        XCTAssertEqual(ChromiumBrowser.from(name: "Edge"), .edge)
        XCTAssertEqual(ChromiumBrowser.from(name: "Brave"), .brave)
        XCTAssertNil(ChromiumBrowser.from(name: "Opera"))
        XCTAssertNil(ChromiumBrowser.from(name: nil))
    }

    func testExtensionsPages() {
        XCTAssertEqual(ChromiumBrowser.chrome.extensionsPage, "chrome://extensions")
        XCTAssertEqual(ChromiumBrowser.edge.extensionsPage, "edge://extensions")
        XCTAssertEqual(ChromiumBrowser.brave.extensionsPage, "brave://extensions")
        XCTAssertEqual(ChromiumBrowser.arc.extensionsPage, "chrome://extensions")
        XCTAssertEqual(ChromiumBrowser.chrome.applicationName, "Google Chrome")
    }
}

final class HelloOpTests: XCTestCase {
    final class Host: OTPBridgeHost {
        var phoneConnected = true
        var hellos: [(String?, String?)] = []
        func autofillAllowed(domain: String) -> Bool { false }
        func setAutofill(domain: String, enabled: Bool) {}
        func extensionHello(browser: String?, parent: String?) { hellos.append((browser, parent)) }
    }

    func testHelloIsAnsweredAndPassedToTheHost() async {
        let b = AuthBroker(transport: FakeAuthTransport())
        let h = Host()
        let r = await OTPBridge(broker: b, host: h).handle(["op": "hello", "browser": "Edge", "parent": "/Applications/Arc.app/Contents/MacOS/Arc", "id": 7])
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["id"] as? Int, 7)
        XCTAssertEqual(h.hellos.count, 1)
        XCTAssertEqual(h.hellos.first?.0, "Edge")
        XCTAssertEqual(h.hellos.first?.1, "/Applications/Arc.app/Contents/MacOS/Arc")
        XCTAssertTrue(OTPBridge.ops.contains("hello"))
    }
}
