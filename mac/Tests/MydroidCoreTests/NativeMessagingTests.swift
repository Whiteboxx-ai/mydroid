import XCTest
import CryptoKit
@testable import MydroidNM

final class NativeMessagingFramingTests: XCTestCase {
    func testFrameIsLittleEndianLengthThenJSON() {
        let f = NativeMessaging.frame(Data("{\"a\":1}".utf8))
        XCTAssertEqual(Array(f.prefix(4)), [7, 0, 0, 0])
        XCTAssertEqual(String(decoding: f.dropFirst(4), as: UTF8.self), "{\"a\":1}")
        let big = NativeMessaging.frame(Data(repeating: 0x20, count: 0x0102))
        XCTAssertEqual(Array(big.prefix(4)), [0x02, 0x01, 0, 0])
    }

    func testDecoderHandlesSplitAndCoalescedReads() throws {
        var d = NativeMessaging.FrameDecoder()
        let a = NativeMessaging.frame(Data("{\"id\":1}".utf8)), b = NativeMessaging.frame(Data("{\"id\":2}".utf8))
        let all = a + b
        d.append(all.prefix(3))
        XCTAssertNil(try d.next())
        d.append(all.dropFirst(3).prefix(5))
        XCTAssertNil(try d.next())
        d.append(all.dropFirst(8))
        XCTAssertEqual(String(decoding: try d.next()!, as: UTF8.self), "{\"id\":1}")
        XCTAssertEqual(String(decoding: try d.next()!, as: UTF8.self), "{\"id\":2}")
        XCTAssertNil(try d.next())
    }

    func testOversizedFrameIsRejected() {
        var d = NativeMessaging.FrameDecoder()
        d.append(Data([0xFF, 0xFF, 0xFF, 0x7F]))
        XCTAssertThrowsError(try d.next())
        XCTAssertNil(NativeMessaging.frame(object: ["x": String(repeating: "a", count: NativeMessaging.maxToBrowser)]))
        XCTAssertNotNil(NativeMessaging.frame(object: ["ok": true]))
    }

    func testOriginCheck() {
        XCTAssertTrue(NativeMessaging.isAllowed(origin: "chrome-extension://\(NativeMessaging.extensionID)/"))
        XCTAssertTrue(NativeMessaging.isAllowed(origin: "chrome-extension://nciekoppmimmlhhhcjknedbggbhafoim/"))
        XCTAssertFalse(NativeMessaging.isAllowed(origin: "chrome-extension://abcdefghijklmnopabcdefghijklmnop/"))
        XCTAssertFalse(NativeMessaging.isAllowed(origin: nil))
    }

    /// The fixed extension ID must be the one Chrome derives from the `key` in extension/manifest.json.
    func testExtensionIDMatchesManifestKey() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("extension/manifest.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let key = try XCTUnwrap(obj["key"] as? String)
        let der = try XCTUnwrap(Data(base64Encoded: key))
        let hex = SHA256.hash(data: der).prefix(16).map { String(format: "%02x", $0) }.joined()
        let id = String(hex.map { c -> Character in Character(UnicodeScalar(UInt8(97) + UInt8(String(c), radix: 16)!)) })
        XCTAssertEqual(id, NativeMessaging.extensionID)
        XCTAssertEqual(obj["manifest_version"] as? Int, 3)
    }
}

final class ManifestInstallerTests: XCTestCase {
    var home: URL!
    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    let host = "/Applications/Mydroid.app/Contents/MacOS/mydroid-nmhost"

    func testManifestContent() throws {
        let o = try JSONSerialization.jsonObject(with: HostManifest.data(hostPath: host)) as! [String: Any]
        XCTAssertEqual(o["name"] as? String, "com.mydroid.otp")
        XCTAssertEqual(o["type"] as? String, "stdio")
        XCTAssertEqual(o["path"] as? String, host)
        XCTAssertEqual(o["allowed_origins"] as? [String], [
            "chrome-extension://\(NativeMessaging.extensionID)/",
            "chrome-extension://nciekoppmimmlhhhcjknedbggbhafoim/",
        ])
        XCTAssertNotNil(o["description"] as? String)
    }

    func testPathsPerBrowser() {
        let base = home.appendingPathComponent("Library/Application Support").path
        XCTAssertEqual(ChromiumBrowser.chrome.manifestURL(home: home).path, base + "/Google/Chrome/NativeMessagingHosts/com.mydroid.otp.json")
        XCTAssertEqual(ChromiumBrowser.edge.manifestURL(home: home).path, base + "/Microsoft Edge/NativeMessagingHosts/com.mydroid.otp.json")
        XCTAssertEqual(ChromiumBrowser.brave.manifestURL(home: home).path, base + "/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.mydroid.otp.json")
        XCTAssertEqual(ChromiumBrowser.arc.manifestURL(home: home).path, base + "/Arc/User Data/NativeMessagingHosts/com.mydroid.otp.json")
    }

    func testInstallStateRemove() throws {
        let b = ChromiumBrowser.brave
        XCTAssertEqual(ManifestInstaller.state(b, home: home, hostPath: host), .notInstalled)
        let url = try ManifestInstaller.install(b, home: home, hostPath: host)
        XCTAssertEqual(url, b.manifestURL(home: home))
        XCTAssertEqual(ManifestInstaller.state(b, home: home, hostPath: host), .installed)
        XCTAssertEqual(ManifestInstaller.state(b, home: home, hostPath: "/elsewhere/mydroid-nmhost"), .outdated, "the app moved")
        XCTAssertEqual(ManifestInstaller.state(.chrome, home: home, hostPath: host), .notInstalled, "other browsers are untouched")
        _ = try ManifestInstaller.install(b, home: home, hostPath: "/new/path")        // reinstall replaces
        XCTAssertEqual(ManifestInstaller.state(b, home: home, hostPath: "/new/path"), .installed)
        ManifestInstaller.remove(b, home: home)
        XCTAssertEqual(ManifestInstaller.state(b, home: home, hostPath: host), .notInstalled)
    }

    func testDetectsInstalledBrowsers() throws {
        let apps = home.appendingPathComponent("Applications", isDirectory: true)
        XCTAssertFalse(ManifestInstaller.isInstalled(.arc, home: home, applicationDirectories: [apps]))
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Arc.app"), withIntermediateDirectories: true)
        XCTAssertTrue(ManifestInstaller.isInstalled(.arc, home: home, applicationDirectories: [apps]))
        try FileManager.default.createDirectory(at: ChromiumBrowser.edge.supportDirectory(home: home), withIntermediateDirectories: true)
        XCTAssertTrue(ManifestInstaller.isInstalled(.edge, home: home, applicationDirectories: []), "a profile folder counts")
        XCTAssertFalse(ManifestInstaller.isInstalled(.chrome, home: home, applicationDirectories: [apps]))
    }
}

final class OTPSocketTests: XCTestCase {
    func shortDir() throws -> URL {
        let d = URL(fileURLWithPath: "/tmp/mdr-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testRoundTripModeAndCleanup() throws {
        let dir = try shortDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("otp.sock").path
        let server = OTPSocketServer(path: path) { line, reply in
            var obj = (try! JSONSerialization.jsonObject(with: line)) as! [String: Any]
            obj["echo"] = true
            reply(try! JSONSerialization.data(withJSONObject: obj))
        }
        try server.start()
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let reply = try OTPSocket.request(path: path, payload: Data("{\"op\":\"status\",\"id\":3}".utf8), timeout: 5)
        let obj = try JSONSerialization.jsonObject(with: reply) as! [String: Any]
        XCTAssertEqual(obj["echo"] as? Bool, true)
        XCTAssertEqual(obj["id"] as? Int, 3)
        // Several at once, one slow: a slow request does not hold up the others.
        let slow = OTPSocketServer(path: dir.appendingPathComponent("b.sock").path) { line, reply in
            let o = (try! JSONSerialization.jsonObject(with: line)) as! [String: Any]
            DispatchQueue.global().asyncAfter(deadline: .now() + (o["slow"] as? Bool == true ? 0.6 : 0)) { reply(line) }
        }
        try slow.start()
        let bpath = dir.appendingPathComponent("b.sock").path
        let g = DispatchGroup(); var order: [String] = []; let lock = NSLock()
        for (name, body) in [("slow", "{\"slow\":true}"), ("fast", "{\"slow\":false}")] {
            g.enter()
            DispatchQueue.global().async {
                _ = try? OTPSocket.request(path: bpath, payload: Data(body.utf8), timeout: 5)
                lock.lock(); order.append(name); lock.unlock(); g.leave()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        g.wait()
        XCTAssertEqual(order, ["fast", "slow"])
        slow.stop()

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try OTPSocket.request(path: path, payload: Data("{}".utf8))) { XCTAssertEqual($0 as? OTPSocket.Failure, .noServer) }
    }

    func testSecondServerDoesNotStealALiveSocketButReplacesAStaleOne() throws {
        let dir = try shortDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("otp.sock").path
        let first = OTPSocketServer(path: path) { l, r in r(l) }
        try first.start()
        let second = OTPSocketServer(path: path) { l, r in r(l) }
        XCTAssertThrowsError(try second.start()) { XCTAssertEqual($0 as? OTPSocket.Failure, .inUse) }
        XCTAssertNoThrow(try OTPSocket.request(path: path, payload: Data("{}".utf8), timeout: 3))
        first.stop()
        // A stale file (a crashed app) is replaced.
        FileManager.default.createFile(atPath: path, contents: Data())
        XCTAssertNoThrow(try second.start())
        second.stop()
    }

    func testLaunchHookIsCalledOnceAndRetried() throws {
        let dir = try shortDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("otp.sock").path
        var server: OTPSocketServer?
        var launches = 0
        let reply = try OTPSocket.request(path: path, payload: Data("{\"a\":1}".utf8), timeout: 3, launch: {
            launches += 1
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                let s = OTPSocketServer(path: path) { l, r in r(l) }
                try? s.start(); server = s
            }
        }, launchWait: 4)
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(String(decoding: reply, as: UTF8.self), "{\"a\":1}")
        server?.stop()
    }

    func testNoServerAfterLaunchWaitFails() throws {
        let dir = try shortDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("none.sock").path
        XCTAssertThrowsError(try OTPSocket.request(path: path, payload: Data("{}".utf8), timeout: 1, launch: {}, launchWait: 0.6)) {
            XCTAssertEqual($0 as? OTPSocket.Failure, .noServer)
        }
    }

    func testPathsAndLimits() {
        let home = URL(fileURLWithPath: "/Users/x", isDirectory: true)
        XCTAssertEqual(OTPSocket.defaultPath(home: home, env: [:]), "/Users/x/Library/Application Support/Mydroid/otp.sock")
        XCTAssertEqual(OTPSocket.defaultPath(home: home, env: ["MYDROID_DATA_DIR": "/tmp/dev"]), "/tmp/dev/otp.sock")
        XCTAssertThrowsError(try OTPSocket.request(path: "/" + String(repeating: "a", count: 200), payload: Data()))
    }
}
