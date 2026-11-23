import XCTest
@testable import MydroidCore

final class CodecTests: XCTestCase {
    func testRoundTrip() throws {
        let m = Message("xfer.chunk", ["xid": "photo:1:100", "offset": 262144, "flag": true], payload: Data([9, 8, 7]))
        let back = try Message.decode(try m.encode())
        XCTAssertEqual(back.type, "xfer.chunk")
        XCTAssertEqual(back.string("xid"), "photo:1:100")
        XCTAssertEqual(back.int("offset"), 262144)
        XCTAssertEqual(back.bool("flag"), true)
        XCTAssertNil(back.int("flag"), "booleans are not ints")
        XCTAssertEqual(back.payload, Data([9, 8, 7]))
    }

    func testBigOffsetsAndUnicode() throws {
        let m = Message("notif.posted", ["when": Int64(1_760_000_000_000), "text": "Café ☕️ \"quoted\" / slash"])
        let back = try Message.decode(try m.encode())
        XCTAssertEqual(back.int("when"), 1_760_000_000_000)
        XCTAssertEqual(back.string("text"), "Café ☕️ \"quoted\" / slash")
    }

    func testRejectsMalformed() {
        XCTAssertThrowsError(try Message.decode(Data([0, 0, 0, 9, 1])))
        XCTAssertThrowsError(try Message.decode(Data([0, 0])))
    }

    func testFrameBufferSplitsAndLimits() throws {
        var fb = FrameBuffer()
        let a = Framing.wrap(Data([1, 2, 3])), b = Framing.wrap(Data([4]))
        let all = a + b
        fb.append(all.prefix(5))
        XCTAssertNil(try fb.next())
        fb.append(all.dropFirst(5))
        XCTAssertEqual(try fb.next(), Data([1, 2, 3]))
        XCTAssertEqual(try fb.next(), Data([4]))
        XCTAssertNil(try fb.next())
        var big = FrameBuffer()
        big.append(Data([0x00, 0x10, 0x00, 0x01]))
        XCTAssertThrowsError(try big.next())
    }

    func testPairingURL() throws {
        let secret = Data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")!
        let url = PairingURL.build(macId: "abc", macName: "Gautam's MacBook & Co", secret: secret, addresses: ["192.168.1.5:47820", "10.0.0.2:47820"])
        XCTAssertEqual(url, "mydroid://pair?v=1&mac=abc&n=Gautam%27s%20MacBook%20%26%20Co&s=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&a=192.168.1.5:47820,10.0.0.2:47820")
        let comps = URLComponents(string: url)!
        XCTAssertEqual(comps.queryItems?.first { $0.name == "n" }?.value, "Gautam's MacBook & Co")
    }

    func testNotificationParsingAndList() {
        let n = PhoneNotification(fields: ["key": "k1", "app": "Messages", "title": "Maya Tan", "text": "Hi", "when": 1000,
                                           "canReply": true, "actions": [["index": 0, "title": "Mark read"]]])!
        XCTAssertEqual(n.initials, "MT")
        XCTAssertTrue(n.canReply)
        XCTAssertEqual(n.actions.first?.title, "Mark read")
        var list = NotificationList()
        XCTAssertTrue(list.post(n))
        XCTAssertFalse(list.post(n))
        XCTAssertEqual(list.items.count, 1)
        list.remove("k1")
        XCTAssertTrue(list.items.isEmpty)
    }

    func testClipboardGuard() {
        var g = ClipboardGuard()
        XCTAssertEqual(g.localChanged("a"), "a")
        XCTAssertNil(g.localChanged("a"))
        g.remoteArrived("from phone")
        XCTAssertNil(g.localChanged("from phone"), "echo of remote text is suppressed")
        XCTAssertEqual(g.localChanged("b"), "b")
    }

    func testFileNaming() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-naming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(FileNaming.sanitize("../../etc/passwd"), "passwd")
        XCTAssertEqual(FileNaming.sanitize(".."), "file")
        let first = FileNaming.uniqueURL(in: dir, name: "a.jpg")
        XCTAssertEqual(first.lastPathComponent, "a.jpg")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = FileNaming.uniqueURL(in: dir, name: "a.jpg")
        XCTAssertEqual(second.lastPathComponent, "a (2).jpg")
        FileManager.default.createFile(atPath: second.path, contents: Data())
        XCTAssertEqual(FileNaming.uniqueURL(in: dir, name: "a.jpg").lastPathComponent, "a (3).jpg")
    }
}
