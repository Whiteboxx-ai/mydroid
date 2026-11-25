import XCTest
@testable import MydroidCore
@testable import Mydroid

/// The real process plumbing, without a phone: the bundled adb on its own port and key home, and the helper's stdin/stdout lines.
final class AdbClientTests: XCTestCase {
    func testRealAdbRunsOnItsOwnServerAndKeyHome() async throws {
        guard let exe = AdbClient.locate() else { throw XCTSkip("no adb on this Mac") }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-adb-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let adb = AdbClient(executable: exe, port: 5197, home: home)      // not 5099, not 5037
        defer { adb.killServer() }
        let up = await adb.ensureServer()
        XCTAssertTrue(up)
        let r = await adb.run(["devices"], timeout: 10)
        XCTAssertTrue(r.ok, r.text)
        XCTAssertTrue(r.out.hasPrefix("List of devices attached"))
        let existing = AdbClient(executable: exe, port: 5197, home: home.appendingPathComponent("unused"), existingServer: true)
        let reused = await existing.run(["devices"], timeout: 3)
        XCTAssertTrue(reused.ok, reused.text)
        existing.killServer()
        let stillRunning = await adb.run(["devices"], timeout: 3)
        XCTAssertTrue(stillRunning.ok, stillRunning.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("unused/.android/adbkey").path))
        // Its key lives under its own HOME, not the developer's ~/.android.
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".android/adbkey").path))
        // Discovery works (the list may well be empty; only the shape is checked).
        let services = await adb.mdnsServices()
        XCTAssertTrue(services.allSatisfy { $0.port > 0 && !$0.host.isEmpty })
        // The default developer server was not involved.
        XCTAssertNotEqual(AdbClient.defaultPort, 5037)
    }

    func testMissingAdbIsReportedNotCrashed() async {
        let adb = AdbClient(executable: nil, home: FileManager.default.temporaryDirectory)
        XCTAssertFalse(adb.isAvailable)
        let up = await adb.ensureServer()
        XCTAssertFalse(up)
        let r = await adb.run(["devices"])
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.err.contains("isn't part of this build"))
    }

    func testHelperProcessLinesInAndOut() throws {
        // Stands in for `adb shell ... app_process`: prints a tier line, waits for a line on stdin, answers it, then quits on `quit`.
        let script = """
        echo 'linker warning: noise'; echo '{"ev":"tier","tier":"listen"}'
        while read l; do case "$l" in *hello*) echo '{"ev":"call","inCall":true}';; *quit*) exit 0;; esac; done
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        let h = AdbHelperProcess(process: p)
        let lock = NSLock()
        var events: [HelperEvent] = []
        var exited: Int32?
        h.onLine = { if let e = HelperProtocol.parse(line: $0) { lock.withLock { events.append(e) } } }
        h.onExit = { code in lock.withLock { exited = code } }
        XCTAssertTrue(h.start())
        h.send(HelperProtocol.hello(macHost: "127.0.0.1", udpPort: 5000, key: Data(repeating: 1, count: 32)))
        let end = Date().addingTimeInterval(5)
        while lock.withLock({ events.count < 2 }), Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(lock.withLock { events }, [.tier(.listen), .call(inCall: true)])
        h.stop()                                                          // sends quit, then makes sure it is gone
        while lock.withLock({ exited == nil }), Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(lock.withLock { exited }, 0)
        h.send("{\"cmd\":\"route\"}\n")                                   // after exit: ignored, no crash
    }
}
