import XCTest
import CryptoKit
@testable import MydroidCore

private func makeTree() throws -> (base: URL, root: URL, outside: URL) {
    let fm = FileManager.default
    // realpath first: /var is a symlink to /private/var and the tests compare real paths.
    let tmp = URL(fileURLWithPath: SharePath.realpath(NSTemporaryDirectory())!)
    let base = tmp.appendingPathComponent("mydroid-fs-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("root", isDirectory: true)
    let outside = base.appendingPathComponent("outside", isDirectory: true)
    try fm.createDirectory(at: root.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("a".utf8).write(to: root.appendingPathComponent("a.txt"))
    try Data("bb".utf8).write(to: root.appendingPathComponent("sub/b.txt"))
    try Data("ccc".utf8).write(to: root.appendingPathComponent("sub/deep/c.txt"))
    try Data("cfg".utf8).write(to: root.appendingPathComponent(".git/config"))
    try Data("inside hidden".utf8).write(to: root.appendingPathComponent(".hidden/h.txt"))
    try Data("dotfile".utf8).write(to: root.appendingPathComponent(".DS_Store"))
    try Data("SECRET".utf8).write(to: outside.appendingPathComponent("secret.txt"))
    try fm.createSymbolicLink(at: root.appendingPathComponent("link-out"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
    try fm.createSymbolicLink(at: root.appendingPathComponent("linkdir-out"), withDestinationURL: outside)
    try fm.createSymbolicLink(at: root.appendingPathComponent("link-in"), withDestinationURL: root.appendingPathComponent("sub"))
    try fm.createSymbolicLink(at: root.appendingPathComponent("link-hidden"), withDestinationURL: root.appendingPathComponent(".hidden"))
    try fm.createSymbolicLink(at: root.appendingPathComponent("dangling"), withDestinationURL: root.appendingPathComponent("nothing-here"))
    try fm.createSymbolicLink(atPath: root.appendingPathComponent("up").path, withDestinationPath: "..")    // relative: the folder above the root
    try fm.createSymbolicLink(at: root.appendingPathComponent("abs-etc"), withDestinationURL: URL(fileURLWithPath: "/etc"))
    return (base, root, outside)
}

final class SharePathTests: XCTestCase {
    var base: URL!, root: URL!, outside: URL!
    override func setUpWithError() throws { (base, root, outside) = try makeTree() }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private func denied(_ p: SharePath, _ rel: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try p.resolve(rel), "'\(rel)' must be refused", file: file, line: line) {
            XCTAssertEqual($0 as? FileShareError, .denied, "'\(rel)'", file: file, line: line)
        }
    }

    func testComponentValidation() throws {
        XCTAssertEqual(try SharePath.components(""), [])
        XCTAssertEqual(try SharePath.components("a/b"), ["a", "b"])
        XCTAssertEqual(try SharePath.components("a/b/"), ["a", "b"], "one trailing slash is fine")
        XCTAssertEqual(try SharePath.components("Photos 2024/IMG 1.jpg"), ["Photos 2024", "IMG 1.jpg"])
        for bad in ["/etc/passwd", "/", "..", "../x", "a/../b", "a/..", "./a", "a/./b", "a//b", "//a", ".hidden", "a/.hidden/b", ".git/config", "a\0b", "a/b//", "\0"] {
            XCTAssertThrowsError(try SharePath.components(bad), "'\(bad.debugDescription)'") { XCTAssertEqual($0 as? FileShareError, .denied) }
        }
    }

    func testResolvesNormalPathsInsideTheRoot() throws {
        let p = try XCTUnwrap(SharePath(root: root))
        XCTAssertEqual(try p.resolve("").path, root.path)
        XCTAssertEqual(try p.resolve("a.txt").path, root.appendingPathComponent("a.txt").path)
        XCTAssertEqual(try p.resolve("sub/deep/c.txt").path, root.appendingPathComponent("sub/deep/c.txt").path)
        XCTAssertEqual(try p.resolve("sub/").path, root.appendingPathComponent("sub").path)
        XCTAssertEqual(p.relativePath(ofRealPath: root.appendingPathComponent("sub/b.txt").path), "sub/b.txt")
        XCTAssertEqual(p.relativePath(ofRealPath: root.path), "")
        XCTAssertNil(p.relativePath(ofRealPath: outside.path))
        XCTAssertNil(p.relativePath(ofRealPath: root.path + "-sibling/x"), "a sibling with the same prefix is outside")
    }

    func testTraversalAndAbsolutePathsAreRefused() throws {
        let p = try XCTUnwrap(SharePath(root: root))
        for bad in ["..", "../outside/secret.txt", "sub/../../outside/secret.txt", "sub/../a.txt", "/etc/passwd", "/" + outside.path,
                    outside.path, "sub//b.txt", ".git/config", ".DS_Store", ".hidden/h.txt", "sub/.x"] {
            denied(p, bad)
        }
    }

    func testSymlinksOutOfTheRootAreRefused() throws {
        let p = try XCTUnwrap(SharePath(root: root))
        denied(p, "link-out")
        denied(p, "linkdir-out")
        denied(p, "linkdir-out/secret.txt")
        denied(p, "up")
        denied(p, "up/outside/secret.txt")
        denied(p, "abs-etc")
        denied(p, "abs-etc/hosts")
    }

    func testSymlinkIntoHiddenFolderIsRefusedAndInsideLinkIsFine() throws {
        let p = try XCTUnwrap(SharePath(root: root))
        denied(p, "link-hidden")
        denied(p, "link-hidden/h.txt")
        XCTAssertEqual(try p.resolve("link-in/b.txt").path, root.appendingPathComponent("sub/b.txt").path, "resolved to the real path, which is inside")
    }

    func testMissingAndDanglingAreNotFound() throws {
        let p = try XCTUnwrap(SharePath(root: root))
        for rel in ["nope.txt", "sub/nope", "dangling"] {
            XCTAssertThrowsError(try p.resolve(rel)) { XCTAssertEqual($0 as? FileShareError, .notFound, rel) }
        }
    }

    func testRootThatIsItselfASymlinkIsConfinedToItsTarget() throws {
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let p = try XCTUnwrap(SharePath(root: alias))
        XCTAssertEqual(p.root, root.path)
        XCTAssertEqual(try p.resolve("a.txt").path, root.appendingPathComponent("a.txt").path)
        denied(p, "link-out")
        XCTAssertNil(SharePath(root: base.appendingPathComponent("gone")))
    }

    func testListingSkipsHiddenAndEscapingEntriesAndSortsFoldersFirst() throws {
        let p = try XCTUnwrap(SharePath(root: root))
        try Data("z".utf8).write(to: root.appendingPathComponent("B 10.pdf"))
        try Data("z".utf8).write(to: root.appendingPathComponent("B 2.pdf"))
        let list = try ShareListing.list(dir: try p.resolve(""), in: p)
        let names = list.map(\.name)
        XCTAssertEqual(names, ["link-in", "sub", "a.txt", "B 2.pdf", "B 10.pdf"], "folders first, Finder-style number ordering")
        for hidden in [".git", ".hidden", ".DS_Store", "link-out", "linkdir-out", "link-hidden", "dangling", "up", "abs-etc"] {
            XCTAssertFalse(names.contains(hidden), hidden)
        }
        let a = try XCTUnwrap(list.first { $0.name == "a.txt" })
        XCTAssertFalse(a.dir)
        XCTAssertEqual(a.size, 1)
        XCTAssertEqual(a.mime, "text/plain")
        XCTAssertGreaterThan(a.mtime, 1_600_000_000_000)
        let sub = try XCTUnwrap(list.first { $0.name == "sub" })
        XCTAssertTrue(sub.dir)
        XCTAssertEqual(sub.mime, "inode/directory")
        XCTAssertEqual(try XCTUnwrap(list.first { $0.name == "link-in" }).dir, true)
        XCTAssertEqual(ShareMime.forFile(named: "x.jpg"), "image/jpeg")
        XCTAssertEqual(ShareMime.forFile(named: "x.unknownext"), "application/octet-stream")
    }

    func testBigFolderIsCappedUnderTheFrameLimit() throws {
        let p = try XCTUnwrap(SharePath(root: root))
        let big = root.appendingPathComponent("big", isDirectory: true)
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        for i in 0..<6000 { FileManager.default.createFile(atPath: big.appendingPathComponent("file-with-a-fairly-long-name-\(i).txt").path, contents: nil) }
        let list = try ShareListing.list(dir: big, in: p)
        XCTAssertEqual(list.count, ShareListing.maxEntries)
        let json = try JSONSerialization.data(withJSONObject: list.map(\.json))
        XCTAssertLessThan(json.count, 800_000)
    }
}

// MARK: Settings

final class FileShareSettingsTests: XCTestCase {
    var base: URL!, root: URL!, outside: URL!
    override func setUpWithError() throws { (base, root, outside) = try makeTree() }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    func testStandardRootsAreReadOnlyAndShareIsOnByDefault() throws {
        let s = FileShareSettings.standard(desktop: root.appendingPathComponent("sub"), documents: root.appendingPathComponent("sub/deep"), downloads: outside)
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.roots.map(\.name), ["Desktop", "Documents", "Downloads"])
        XCTAssertEqual(s.roots.map(\.id), ["desktop", "documents", "downloads"])
        XCTAssertTrue(s.roots.allSatisfy { !$0.writable }, "saving to the Mac is off by default")
        let r = s.resolved()
        XCTAssertEqual(r.config.roots.count, 3)
        XCTAssertNil(r.updated)
        let back = try JSONDecoder().decode(FileShareSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testAddingFoldersDedupesAndNamesUniquely() throws {
        var s = FileShareSettings(roots: [])
        XCTAssertNotNil(s.add(root.appendingPathComponent("sub")))
        XCTAssertNil(s.add(root.appendingPathComponent("sub")), "same folder twice")
        XCTAssertNil(s.add(root.appendingPathComponent("link-in")), "a link to a folder already shared")
        let other = base.appendingPathComponent("elsewhere/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let id = try XCTUnwrap(s.add(other))
        XCTAssertEqual(s.roots.map(\.name), ["sub", "sub 2"])
        XCTAssertEqual(id.count, 36)
        XCTAssertEqual(Set(s.roots.map(\.id)).count, 2)
    }

    func testMissingFoldersDropOutAndMovedFoldersAreFollowedByBookmark() throws {
        let dir = base.appendingPathComponent("movable", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = FileShareSettings(roots: [FileShareRootSetting(id: "m", name: "Movable", url: dir, writable: true),
                                          FileShareRootSetting(id: "g", name: "Gone", url: base.appendingPathComponent("never-existed"))])
        XCTAssertEqual(s.roots[0].bookmark != nil, true)
        var r = s.resolved()
        XCTAssertEqual(r.config.roots.map(\.id), ["m"], "a folder that doesn't exist isn't shared")
        XCTAssertTrue(r.config.roots[0].writable)

        let moved = base.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: dir, to: moved)
        r = s.resolved()
        XCTAssertEqual(r.config.roots.count, 1, "the bookmark follows the folder")
        XCTAssertEqual(SharePath.realpath(r.config.roots[0].url.path), SharePath.realpath(moved.path))
        let updated = try XCTUnwrap(r.updated, "the stored path is refreshed")
        XCTAssertEqual(updated.roots[0].path, r.config.roots[0].url.path)
        XCTAssertEqual(updated.roots[0].id, "m")
        XCTAssertTrue(updated.roots[0].writable)
    }

    func testDuplicateIdsAreSharedOnce() {
        let u = root!
        let s = FileShareSettings(roots: [FileShareRootSetting(id: "x", name: "A", url: u), FileShareRootSetting(id: "x", name: "B", url: u)])
        XCTAssertEqual(s.resolved().config.roots.count, 1)
    }
}

// MARK: The service

private final class FakeThumbs: FileThumbnailProvider {
    var inFlight = 0, maxInFlight = 0
    var held: [(URL, (Data?) -> Void)] = []
    var holdAll = false
    var result: Data? = Data([0xff, 0xd8, 1, 2, 3])
    private let lock = NSLock()
    func thumbnail(for url: URL, maxPixel: Int, completion: @escaping (Data?) -> Void) {
        lock.lock(); inFlight += 1; maxInFlight = max(maxInFlight, inFlight)
        if holdAll { held.append((url, { [self] d in lock.lock(); inFlight -= 1; lock.unlock(); completion(d) })); lock.unlock(); return }
        inFlight -= 1; lock.unlock()
        completion(result)
    }
}

private final class FakeSearch: FileSearchProvider {
    var urls: [URL] = []
    var lastQuery: String?
    var lastRoots: [URL] = []
    var recentCalled = false
    func search(query: String, in roots: [URL], limit: Int, completion: @escaping ([URL]) -> Void) { lastQuery = query; lastRoots = roots; completion(urls) }
    func recent(in roots: [URL], limit: Int, completion: @escaping ([URL]) -> Void) { recentCalled = true; lastRoots = roots; completion(urls) }
}

final class FileShareServiceTests: XCTestCase {
    var base: URL!, root: URL!, outside: URL!
    let queue = DispatchQueue(label: "test.fs")
    var sent: [Message] = []
    var offered: [(URL, String)] = []
    var offerResult = true
    var service: FileShareService!
    private var thumbs = FakeThumbs()
    private var search = FakeSearch()

    override func setUpWithError() throws {
        (base, root, outside) = try makeTree()
        service = FileShareService(queue: queue, macName: "Test Mac", send: { [unowned self] m in self.sent.append(m) },
                                   offer: { [unowned self] u, x in self.offered.append((u, x)); return self.offerResult })
        service.thumbnails = thumbs
        service.search = search
        service.update(FileShareConfig(enabled: true, roots: [ShareRoot(id: "docs", name: "Documents", url: root, writable: false),
                                                              ShareRoot(id: "inbox", name: "Inbox", url: root.appendingPathComponent("sub"), writable: true)]))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private func call(_ type: String, _ fields: [String: Any]) -> [Message] {
        sent = []
        queue.sync { _ = service.handle(Message(type, fields)) }
        return queue.sync { sent }
    }

    private func settle() { queue.sync {} }

    func testRootsListsOnlyWhenOn() throws {
        var out = call("fs.roots", ["req": "r1"])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].type, "fs.roots.result")
        XCTAssertEqual(out[0].string("req"), "r1")
        XCTAssertEqual(out[0].string("macName"), "Test Mac")
        let roots = try XCTUnwrap(out[0].array("roots"))
        XCTAssertEqual(roots.map { $0["id"] as? String }, ["docs", "inbox"])
        XCTAssertEqual(roots.map { $0["writable"] as? Bool }, [false, true])
        queue.sync { service.update(FileShareConfig(enabled: false, roots: service.config.roots)) }
        out = call("fs.roots", ["req": 7])
        XCTAssertEqual(out[0].int("req"), 7, "numeric ids come back as numbers")
        XCTAssertEqual(out[0].array("roots")?.count, 0, "an empty list means sharing is off")
    }

    func testRequestsWithoutReqAreIgnoredAndOthersAreNotOurs() {
        XCTAssertTrue(call("fs.list", ["root": "docs"]).isEmpty)
        queue.sync {
            XCTAssertFalse(service.handle(Message("notif.posted")))
            XCTAssertTrue(service.handle(Message("fs.unknown", ["req": 1])))
        }
    }

    func testListReturnsItemsAndErrors() throws {
        var out = call("fs.list", ["req": 1, "root": "docs", "path": ""])
        let items = try XCTUnwrap(out[0].array("items"))
        XCTAssertEqual(items.compactMap { $0["name"] as? String }, ["link-in", "sub", "a.txt"])
        XCTAssertEqual(Set(items[2].keys), ["name", "dir", "size", "mtime", "mime"])
        out = call("fs.list", ["req": 2, "root": "docs", "path": "sub"])
        XCTAssertEqual(out[0].array("items")?.compactMap { $0["name"] as? String }, ["deep", "b.txt"])
        out = call("fs.list", ["req": 3, "root": "docs"])          // path omitted = the root
        XCTAssertNotNil(out[0].array("items"))
        for (path, err) in [("../outside", "denied"), ("/etc", "denied"), ("link-out", "denied"), ("linkdir-out", "denied"),
                            (".git", "denied"), ("missing", "not_found"), ("a.txt", "not_found")] {
            out = call("fs.list", ["req": 4, "root": "docs", "path": path])
            XCTAssertEqual(out[0].type, "fs.list.result", path)
            XCTAssertEqual(out[0].string("error"), err, path)
            XCTAssertNil(out[0].array("items"), path)
        }
        out = call("fs.list", ["req": 5, "root": "nope", "path": ""])
        XCTAssertEqual(out[0].string("error"), "not_found")
        queue.sync { service.update(FileShareConfig(enabled: false, roots: service.config.roots)) }
        out = call("fs.list", ["req": 6, "root": "docs", "path": ""])
        XCTAssertEqual(out[0].string("error"), "off")
    }

    func testGetOffersTheFileUnderFsXid() throws {
        let out = call("fs.get", ["req": "abc", "root": "docs", "path": "sub/b.txt"])
        XCTAssertTrue(out.isEmpty, "the answer is the transfer itself")
        XCTAssertEqual(offered.count, 1)
        XCTAssertEqual(offered[0].0.path, root.appendingPathComponent("sub/b.txt").path)
        XCTAssertEqual(offered[0].1, "fs:abc")
        _ = call("fs.get", ["req": 12, "root": "docs", "path": "link-in/b.txt"])
        XCTAssertEqual(offered.last?.1, "fs:12")
        XCTAssertTrue(isFileShareGet("fs:12"))
        XCTAssertFalse(isFileShareGet("fsput:12"))
    }

    func testGetRefusesWhatItShould() {
        offered = []
        for (path, err) in [("../outside/secret.txt", "denied"), ("link-out", "denied"), ("/etc/hosts", "denied"), (".git/config", "denied"),
                            ("sub", "not_found"), ("", "not_found"), ("missing", "not_found")] {
            let out = call("fs.get", ["req": 1, "root": "docs", "path": path])
            XCTAssertEqual(out.first?.type, "fs.error", path)
            XCTAssertEqual(out.first?.string("error"), err, path)
        }
        XCTAssertTrue(offered.isEmpty)
        offerResult = false
        XCTAssertEqual(call("fs.get", ["req": 1, "root": "docs", "path": "a.txt"]).first?.type, "fs.error")
        queue.sync { service.update(FileShareConfig(enabled: false, roots: service.config.roots)) }
        XCTAssertEqual(call("fs.get", ["req": 1, "root": "docs", "path": "a.txt"]).first?.string("error"), "off")
    }

    func testPutIsOnlyForWritableRootsAndSingleUse() throws {
        var out = call("fs.put", ["req": 1, "root": "docs", "path": "", "name": "x.txt", "size": 3])
        XCTAssertEqual(out[0].type, "fs.error")
        XCTAssertEqual(out[0].string("error"), "denied", "read-only root")
        out = call("fs.put", ["req": 2, "root": "inbox", "path": "", "name": "../../evil.sh", "size": 3])
        XCTAssertEqual(out[0].type, "fs.put.ready")
        let ok = queue.sync { service.consumePut(xid: "fsput:2") }
        XCTAssertEqual(ok?.name, "evil.sh", "the name is stripped of path parts")
        XCTAssertEqual(ok?.dir.path, root.appendingPathComponent("sub").path)
        XCTAssertNil(queue.sync { service.consumePut(xid: "fsput:2") }, "good for one offer")
        XCTAssertNil(queue.sync { service.consumePut(xid: "fsput:999") }, "never announced")
    }

    func testPutRefusals() {
        let cases: [(String, [String: Any], String)] = [
            ("traversal", ["root": "inbox", "path": "../..", "name": "x", "size": 1], "denied"),
            ("absolute", ["root": "inbox", "path": "/tmp", "name": "x", "size": 1], "denied"),
            ("symlink out", ["root": "docs", "path": "linkdir-out", "name": "x", "size": 1], "denied"),
            ("missing folder", ["root": "inbox", "path": "nope", "name": "x", "size": 1], "not_found"),
            ("folder is a file", ["root": "inbox", "path": "b.txt", "name": "x", "size": 1], "not_found"),
            ("hidden name", ["root": "inbox", "path": "", "name": ".bashrc", "size": 1], "denied"),
            ("no name", ["root": "inbox", "path": "", "size": 1], "denied"),
            ("no size", ["root": "inbox", "path": "", "name": "x"], "denied"),
            ("negative size", ["root": "inbox", "path": "", "name": "x", "size": -1], "denied"),
        ]
        for (label, fields, err) in cases {
            var f = fields; f["req"] = 5
            let out = call("fs.put", f)
            XCTAssertEqual(out.first?.type, "fs.error", label)
            XCTAssertEqual(out.first?.string("error"), err, label)
        }
        XCTAssertNil(queue.sync { service.consumePut(xid: "fsput:5") })
    }

    func testPutIsRecheckedAgainstSettingsAtOfferTime() {
        XCTAssertEqual(call("fs.put", ["req": 3, "root": "inbox", "path": "deep", "name": "x.txt", "size": 1])[0].type, "fs.put.ready")
        queue.sync { service.update(FileShareConfig(enabled: true, roots: [ShareRoot(id: "inbox", name: "Inbox", url: root.appendingPathComponent("sub"), writable: false)])) }
        XCTAssertNil(queue.sync { service.consumePut(xid: "fsput:3") }, "turning writes off cancels pending uploads")
        XCTAssertEqual(call("fs.put", ["req": 4, "root": "inbox", "path": "deep", "name": "x.txt", "size": 1])[0].string("error"), "denied")
        queue.sync { service.update(FileShareConfig(enabled: true, roots: [ShareRoot(id: "inbox", name: "Inbox", url: root.appendingPathComponent("sub"), writable: true)])) }
        XCTAssertEqual(call("fs.put", ["req": 6, "root": "inbox", "path": "deep", "name": "x.txt", "size": 1])[0].type, "fs.put.ready")
        XCTAssertEqual(queue.sync { service.consumePut(xid: "fsput:6") }?.dir.lastPathComponent, "deep")
    }

    func testReapplyingTheSameSettingsKeepsAPendingUpload() {
        XCTAssertEqual(call("fs.put", ["req": 8, "root": "inbox", "path": "", "name": "x.txt", "size": 1])[0].type, "fs.put.ready")
        queue.sync { service.update(service.config) }          // e.g. a bookmark refresh on reconnect
        XCTAssertNotNil(queue.sync { service.consumePut(xid: "fsput:8") })
    }

    func testThumbnails() throws {
        var out = call("fs.thumb", ["req": 1, "root": "docs", "path": "a.txt"])
        settle()
        out = queue.sync { sent }
        XCTAssertEqual(out.first?.type, "fs.thumb.result")
        XCTAssertEqual(out.first?.bool("ok"), true)
        XCTAssertEqual(out.first?.payload, Data([0xff, 0xd8, 1, 2, 3]))
        for bad in ["../outside/secret.txt", "link-out", "sub", "missing", ".git/config"] {
            _ = call("fs.thumb", ["req": 2, "root": "docs", "path": bad])
            settle()
            let r = queue.sync { sent }
            XCTAssertEqual(r.first?.bool("ok"), false, bad)
            XCTAssertTrue(r.first?.payload.isEmpty ?? false)
        }
        thumbs.result = nil
        _ = call("fs.thumb", ["req": 3, "root": "docs", "path": "a.txt"]); settle()
        XCTAssertEqual(queue.sync { sent }.first?.bool("ok"), false)
        thumbs.result = Data(repeating: 1, count: 900_000)
        _ = call("fs.thumb", ["req": 4, "root": "docs", "path": "a.txt"]); settle()
        XCTAssertEqual(queue.sync { sent }.first?.bool("ok"), false, "too big for a frame")
    }

    func testThumbnailWorkIsLimitedAndAllAnswered() throws {
        thumbs.holdAll = true
        sent = []
        for i in 0..<20 { queue.sync { _ = service.handle(Message("fs.thumb", ["req": i, "root": "docs", "path": "a.txt"])) } }
        XCTAssertEqual(thumbs.held.count, 6, "no more than six at a time")
        var answered = 0
        while !thumbs.held.isEmpty {
            let (_, done) = thumbs.held.removeFirst()
            done(Data([1]))
            settle()
            answered += 1
            XCTAssertLessThanOrEqual(thumbs.held.count, 6)
        }
        XCTAssertEqual(answered, 20)
        XCTAssertEqual(queue.sync { sent }.count, 20)
        XCTAssertLessThanOrEqual(thumbs.maxInFlight, 6)
    }

    func testSearchFiltersToTheSharedRoots() throws {
        search.urls = [
            root.appendingPathComponent("a.txt"),
            root.appendingPathComponent("sub/b.txt"),
            root.appendingPathComponent("link-in/b.txt"),              // the same real file again
            outside.appendingPathComponent("secret.txt"),              // outside
            root.appendingPathComponent("link-out"),                   // link that leaves the root
            root.appendingPathComponent(".git/config"),                // hidden
            root.appendingPathComponent("link-hidden/h.txt"),          // through a hidden folder
            root.appendingPathComponent("gone.txt"),                   // not there any more
            root,                                                      // the root itself
            root.appendingPathComponent("sub"),
        ]
        _ = call("fs.search", ["req": 9, "query": "  txt  "]); settle()
        let r = queue.sync { sent }
        XCTAssertEqual(r.first?.type, "fs.search.result")
        XCTAssertEqual(search.lastQuery, "txt")
        let items = try XCTUnwrap(r.first?.array("items"))
        XCTAssertEqual(items.compactMap { $0["path"] as? String }, ["a.txt", "sub/b.txt", "sub"], "the same file isn't listed twice")
        let first = items[0]
        XCTAssertEqual(first["root"] as? String, "docs")
        XCTAssertEqual(first["name"] as? String, "a.txt")
        XCTAssertEqual(first["dir"] as? Bool, false)
        XCTAssertEqual(first["size"] as? Int64, 1)
        XCTAssertEqual(items[2]["dir"] as? Bool, true)
        XCTAssertEqual(Set(first.keys), ["root", "path", "name", "dir", "size", "mtime", "mime"])
        XCTAssertEqual(search.lastRoots.count, 2)
    }

    func testSearchEmptyQueryAndLimits() throws {
        _ = call("fs.search", ["req": 1, "query": "   "]); settle()
        XCTAssertEqual(queue.sync { sent }.first?.array("items")?.count, 0)
        XCTAssertNil(search.lastQuery, "nothing is searched for")
        let many = root.appendingPathComponent("many", isDirectory: true)
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        search.urls = (0..<100).map { i -> URL in
            let u = many.appendingPathComponent("f\(i).txt"); FileManager.default.createFile(atPath: u.path, contents: Data([1])); return u
        }
        _ = call("fs.search", ["req": 2, "query": "f"]); settle()
        XCTAssertEqual(queue.sync { sent }.first?.array("items")?.count, FileShareService.maxSearchResults)
        _ = call("fs.recent", ["req": 3]); settle()
        XCTAssertTrue(search.recentCalled)
        XCTAssertEqual(queue.sync { sent }.first?.array("items")?.count, FileShareService.maxRecentResults)
        queue.sync { service.update(FileShareConfig(enabled: false, roots: service.config.roots)) }
        XCTAssertEqual(call("fs.search", ["req": 4, "query": "f"]).first?.string("error"), "off")
        XCTAssertEqual(call("fs.recent", ["req": 5]).first?.string("error"), "off")
    }

    func testSearchWithoutAProviderAnswersEmpty() {
        service.search = nil
        _ = call("fs.search", ["req": 1, "query": "x"]); settle()
        XCTAssertEqual(queue.sync { sent }.first?.array("items")?.count, 0)
    }
}

// MARK: Through the Hub, over the wire

private final class HubEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HubEvent] = []
    private var cursor = 0
    func add(_ e: HubEvent) { lock.lock(); events.append(e); lock.unlock() }
    func all() -> [HubEvent] { lock.lock(); defer { lock.unlock() }; return events }
    private func scan<T>(_ match: (HubEvent) -> T?) -> T? {
        lock.lock(); defer { lock.unlock() }
        while cursor < events.count {
            let e = events[cursor]; cursor += 1
            if let r = match(e) { return r }
        }
        return nil
    }
    func next<T>(timeout: TimeInterval = 6, _ match: (HubEvent) -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let r = scan(match) { return r }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "test", code: 3, userInfo: [NSLocalizedDescriptionKey: "timed out waiting for a hub event"])
    }
}

class HubFixtureCase: XCTestCase {
    var dir: URL!
    var hub: Hub!
    fileprivate var events: HubEvents!
    var port: UInt16 = 0
    var phone: TestClient!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-hubfx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileKeyValueStore(directory: dir.appendingPathComponent("secrets"))
        hub = Hub(HubConfiguration(macName: "Test Mac", identity: Identity(store: store), config: store,
                                   ledgerURL: dir.appendingPathComponent("ledger.json"),
                                   photosDirectory: dir.appendingPathComponent("Pictures"),
                                   downloadsDirectory: dir.appendingPathComponent("Downloads"),
                                   preferredPort: 0, advertiseBonjour: false))
        events = HubEvents()
        let ev = events!
        hub.onEvent = { ev.add($0) }
        port = try XCTUnwrap(hub.startAndWait())
    }

    override func tearDown() async throws {
        phone?.drop()
        hub.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    /// Pairs a phone called `name` and leaves it connected.
    func pairAndConnect(name: String = "Pixel 9") async throws {
        hub.startPairing()
        var url: String?
        for _ in 0..<200 { url = hub.pairURL; if url != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let comps = try XCTUnwrap(URLComponents(string: try XCTUnwrap(url)))
        let secret = try XCTUnwrap(Data(base64url: try XCTUnwrap(comps.queryItems?.first { $0.name == "s" }?.value)))
        let ltk = MydroidCrypto.ltk(fromPairingSecret: secret)
        let phoneId = UUID().uuidString.lowercased()
        let c1 = TestClient(port: port)
        try await c1.connect()
        try await c1.handshake(phoneId: phoneId, macId: hub.macId, ltk: ltk, pairing: true, name: name)
        _ = try await events.next { e -> Bool? in if case .confirmCode = e { return true } else { return nil } }
        hub.confirmPairing()
        _ = try await c1.receive(type: "pair.confirmed")
        try await c1.send(Message("bye"))
        c1.drop()
        _ = try await events.next { e -> Bool? in if case .sessionClosed = e { return true } else { return nil } }
        phone = TestClient(port: port)
        try await phone.connect()
        try await phone.handshake(phoneId: phoneId, macId: hub.macId, ltk: ltk, pairing: false, name: name)
        try await phone.send(Message("device.status", ["battery": 80, "charging": false, "network": "wifi", "name": name, "model": name]))
        _ = try await phone.receive(type: "settings")
        for _ in 0..<200 where hub.snapshot.link != .connected { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
}

final class HubFileShareTests: HubFixtureCase {
    var tree: (base: URL, root: URL, outside: URL)!

    override func setUp() async throws {
        try await super.setUp()
        tree = try makeTree()
        try await pairAndConnect()
        hub.setFileShare(FileShareConfig(enabled: true, roots: [ShareRoot(id: "docs", name: "Documents", url: tree.root, writable: false),
                                                                ShareRoot(id: "inbox", name: "Inbox", url: tree.root.appendingPathComponent("sub"), writable: true)]))
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tree.base)
        try await super.tearDown()
    }

    func testRootsAndListOverTheWire() async throws {
        try await phone.send(Message("fs.roots", ["req": "r"]))
        let r = try await phone.receive(type: "fs.roots.result")
        XCTAssertEqual(r.array("roots")?.count, 2)
        XCTAssertEqual(r.string("macName"), "Test Mac")
        try await phone.send(Message("fs.list", ["req": "l", "root": "docs", "path": "sub"]))
        let l = try await phone.receive(type: "fs.list.result")
        XCTAssertEqual(l.array("items")?.compactMap { $0["name"] as? String }, ["deep", "b.txt"])
        try await phone.send(Message("fs.list", ["req": "x", "root": "docs", "path": "../outside"]))
        let denied = try await phone.receive(type: "fs.list.result")
        XCTAssertEqual(denied.string("error"), "denied")
    }

    func testGetSendsTheFileViaXferAndLeavesNoSentRecord() async throws {
        let content = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try content.write(to: tree.root.appendingPathComponent("sub/big.bin"))
        try await phone.send(Message("fs.get", ["req": "g1", "root": "docs", "path": "sub/big.bin"]))
        let offer = try await phone.receive(type: "xfer.offer")
        XCTAssertEqual(offer.string("xid"), "fs:g1")
        XCTAssertEqual(offer.string("kind"), "file")
        XCTAssertEqual(offer.string("name"), "big.bin")
        XCTAssertEqual(offer.int("size"), 300_000)
        try await phone.send(Message("xfer.accept", ["xid": "fs:g1", "offset": 0]))
        var got = Data()
        while true {
            let m = try await phone.receive()
            if m.type == "xfer.chunk" { got.append(m.payload) }
            if m.type == "xfer.end" { XCTAssertEqual(m.string("sha256"), sha(content)); break }
        }
        XCTAssertEqual(got, content)
        try await phone.send(Message("xfer.done", ["xid": "fs:g1", "ok": true]))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(events.all().contains { if case .sent = $0 { return true } else { return false } }, "the phone pulling a file isn't a user 'send'")
        XCTAssertTrue(hub.snapshot.transfers.isEmpty)

        try await phone.send(Message("fs.get", ["req": "g2", "root": "docs", "path": "link-out"]))
        let err = try await phone.receive(type: "fs.error")
        XCTAssertEqual(err.string("req"), "g2")
        XCTAssertEqual(err.string("error"), "denied")
    }

    private func upload(_ data: Data, req: String, name: String = "up.txt") async throws -> Message {
        try await phone.send(Message("fs.put", ["req": req, "root": "inbox", "path": "deep", "name": name, "size": data.count]))
        let ready = try await phone.receive()
        guard ready.type == "fs.put.ready" else { return ready }
        let xid = "fsput:\(req)"
        try await phone.send(Message("xfer.offer", ["xid": xid, "kind": "file", "name": name, "size": data.count, "mime": "text/plain"]))
        let accept = try await phone.receive(type: "xfer.accept")
        XCTAssertEqual(accept.int("offset"), 0)
        try await phone.send(Message("xfer.chunk", ["xid": xid, "offset": 0], payload: data))
        try await phone.send(Message("xfer.end", ["xid": xid, "sha256": sha(data)]))
        return try await phone.receive(type: "xfer.done")
    }

    func testPutSavesIntoTheFolderWithUniqueNamesAndStaysOutOfTheLedger() async throws {
        let deep = tree.root.appendingPathComponent("sub/deep")
        for (i, expected) in ["up.txt", "up (2).txt", "up (3).txt"].enumerated() {
            let data = Data("round \(i)".utf8)
            let done = try await upload(data, req: "p\(i)")
            XCTAssertEqual(done.bool("ok"), true)
            XCTAssertEqual(try Data(contentsOf: deep.appendingPathComponent(expected)), data)
        }
        XCTAssertTrue(hub.recentTransfers().isEmpty, "uploads to the Mac aren't in the received-files history")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: deep.path).filter { $0.hasSuffix(".part") }, [])
        // An existing file is never overwritten.
        XCTAssertEqual(try String(contentsOf: deep.appendingPathComponent("c.txt")), "ccc")
        let done = try await upload(Data("new".utf8), req: "p9", name: "c.txt")
        XCTAssertEqual(done.bool("ok"), true)
        XCTAssertEqual(try String(contentsOf: deep.appendingPathComponent("c.txt")), "ccc")
        XCTAssertEqual(try String(contentsOf: deep.appendingPathComponent("c (2).txt")), "new")
    }

    func testPutRefusedInReadOnlyRootAndUnannouncedUploadsAreRefused() async throws {
        try await phone.send(Message("fs.put", ["req": "ro", "root": "docs", "path": "", "name": "x.txt", "size": 1]))
        let e = try await phone.receive()
        XCTAssertEqual(e.type, "fs.error")
        XCTAssertEqual(e.string("error"), "denied")
        // An offer that no fs.put announced is turned away, whatever it is called.
        try await phone.send(Message("xfer.offer", ["xid": "fsput:sneaky", "kind": "file", "name": "x.txt", "size": 1, "mime": "text/plain"]))
        let done = try await phone.receive(type: "xfer.done")
        XCTAssertEqual(done.bool("ok"), false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("x.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("sub/x.txt").path))
        // Turning sharing off stops everything.
        hub.setFileShare(FileShareConfig(enabled: false, roots: []))
        try await phone.send(Message("fs.roots", ["req": "off"]))
        let none = try await phone.receive(type: "fs.roots.result")
        XCTAssertEqual(none.array("roots")?.count, 0)
        try await phone.send(Message("fs.get", ["req": "off", "root": "docs", "path": "a.txt"]))
        let off = try await phone.receive(type: "fs.error")
        XCTAssertEqual(off.string("error"), "off")
    }

    func testDroppedUploadLeavesNoPartialFile() async throws {
        let data = Data(repeating: 5, count: 200_000)
        try await phone.send(Message("fs.put", ["req": "drop", "root": "inbox", "path": "deep", "name": "half.bin", "size": data.count]))
        _ = try await phone.receive(type: "fs.put.ready")
        try await phone.send(Message("xfer.offer", ["xid": "fsput:drop", "kind": "file", "name": "half.bin", "size": data.count, "mime": "x/y"]))
        _ = try await phone.receive(type: "xfer.accept")
        try await phone.send(Message("xfer.chunk", ["xid": "fsput:drop", "offset": 0], payload: data.prefix(50_000)))
        try await Task.sleep(nanoseconds: 200_000_000)
        phone.drop()
        _ = try await events.next { e -> Bool? in if case .sessionClosed = e { return true } else { return nil } }
        let deep = tree.root.appendingPathComponent("sub/deep")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: deep.path).sorted(), ["c.txt"])
    }
}

// MARK: Quick Share through the Hub

final class HubQuickShareTests: HubFixtureCase {
    private func qsPort(_ timeout: TimeInterval = 5) async throws -> UInt16 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let p = hub.quickShare.queue.sync(execute: { hub.quickShare.port }) { return p }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "test", code: 4, userInfo: [NSLocalizedDescriptionKey: "quick share isn't listening"])
    }

    private func qsStopped(_ timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hub.quickShare.queue.sync(execute: { hub.quickShare.port }) == nil { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("quick share is still listening")
    }

    private func sender(name: String, files: [QS.Sharing.FileMetadata] = [], texts: [QS.Sharing.TextMetadata] = []) async throws -> QSTestSender {
        let pipe = try TCPPipe(port: try await qsPort())
        let s = QSTestSender(pipe)
        try s.handshake(name: name)
        try s.introduce(files: files, texts: texts)
        return s
    }

    func testNothingListensUntilConfigured() async throws {
        try await pairAndConnect()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(hub.quickShare.queue.sync { hub.quickShare.port }, "the test server never turns Quick Share on")
    }

    func testOnlyWhenPhoneConnectedFollowsTheLink() async throws {
        hub.setQuickShare(QuickShareSettings())              // the default
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(hub.quickShare.queue.sync { hub.quickShare.port }, "no phone yet")
        try await pairAndConnect()
        _ = try await qsPort()
        phone.drop()
        _ = try await events.next { e -> Bool? in if case .sessionClosed = e { return true } else { return nil } }
        try await qsStopped()
        hub.setQuickShare(QuickShareSettings(visibility: .always))
        _ = try await qsPort()
        hub.setQuickShare(QuickShareSettings(visibility: .off))
        try await qsStopped()
    }

    func testPairedPhoneIsAcceptedWithoutAskingAndTextGoesToTheClipboardEvent() async throws {
        try await pairAndConnect(name: "Pixel 9")
        hub.setQuickShare(QuickShareSettings())
        let s = try await sender(name: "Pixel 9", texts: [.init(title: "note", type: .text, payloadId: 7, size: 5)])
        XCTAssertEqual(try s.nextSharing().responseStatus, 1, "accepted straight away")
        try s.sendBytes(id: 7, Data("hello".utf8))
        let got = try await events.next { e -> (String, String)? in if case let .quickShareText(t, from) = e { return (t, from) } else { return nil } }
        XCTAssertEqual(got.0, "hello")
        XCTAssertEqual(got.1, "Pixel 9")
        XCTAssertFalse(events.all().contains { if case .quickShareRequest = $0 { return true } else { return false } }, "no prompt for your own phone")
    }

    func testUrlFromPairedPhoneBecomesALinkEventAndOtherSchemesBecomeText() async throws {
        try await pairAndConnect(name: "Pixel 9")
        hub.setQuickShare(QuickShareSettings())
        let url = "https://example.com/x"
        var s = try await sender(name: "Pixel 9", texts: [.init(title: url, type: .url, payloadId: 7, size: Int64(url.utf8.count))])
        _ = try s.nextSharing()
        try s.sendBytes(id: 7, Data(url.utf8))
        let link = try await events.next { e -> URL? in if case let .quickShareLink(u, _) = e { return u } else { return nil } }
        XCTAssertEqual(link.absoluteString, url)
        s = try await sender(name: "Pixel 9", texts: [.init(title: "x", type: .url, payloadId: 8, size: 12)])
        _ = try s.nextSharing()
        try s.sendBytes(id: 8, Data("file:///etc/ssh".utf8.prefix(12)))
        let t = try await events.next { e -> String? in if case let .quickShareText(t, _) = e { return t } else { return nil } }
        XCTAssertEqual(t, "file:///etc/", "only http, https and mailto are links; anything else is just text")
    }

    func testStrangerIsAskedAndFilesLandInDownloads() async throws {
        try await pairAndConnect(name: "Pixel 9")
        hub.setQuickShare(QuickShareSettings())
        let data = Data((0..<90_000).map { UInt8(truncatingIfNeeded: $0) })
        let s = try await sender(name: "Dev's Laptop", files: [.init(name: "report.pdf", type: 5, payloadId: 3, size: Int64(data.count), mimeType: "application/pdf")])
        let req = try await events.next { e -> QuickShareIncoming? in if case let .quickShareRequest(r) = e { return r } else { return nil } }
        XCTAssertEqual(req.sender, "Dev's Laptop")
        XCTAssertEqual(req.pin, s.pin)
        XCTAssertEqual(req.summary, "report.pdf")
        XCTAssertEqual(req.fileCount, 1)
        XCTAssertEqual(req.totalBytes, 90_000)
        XCTAssertGreaterThan(req.expires.timeIntervalSinceNow, 25)
        hub.quickShareRespond(id: req.id, accept: true)
        XCTAssertEqual(try s.nextSharing().responseStatus, 1)
        try s.sendFile(id: 3, data: data)
        let done = try await events.next { e -> QuickShareDone? in if case let .quickShareDone(d) = e { return d } else { return nil } }
        XCTAssertEqual(done.sender, "Dev's Laptop")
        let f = try XCTUnwrap(done.files.first)
        XCTAssertEqual(f.url.deletingLastPathComponent().path, dir.appendingPathComponent("Downloads").path)
        XCTAssertEqual(f.kind, "file")
        XCTAssertEqual(try Data(contentsOf: f.url), data)
        // It's in the Files history (the ledger) and the transfer list is clean.
        XCTAssertEqual(hub.recentTransfers().map(\.name), ["report.pdf"])
        XCTAssertTrue(hub.snapshot.transfers.isEmpty)
    }

    func testDecliningRejectsAndNothingIsSaved() async throws {
        try await pairAndConnect(name: "Pixel 9")
        hub.setQuickShare(QuickShareSettings())
        let s = try await sender(name: "Stranger", files: [.init(name: "x.bin", payloadId: 3, size: 10, mimeType: "x/y")])
        let req = try await events.next { e -> QuickShareIncoming? in if case let .quickShareRequest(r) = e { return r } else { return nil } }
        hub.quickShareRespond(id: req.id, accept: false)
        XCTAssertEqual(try s.nextSharing().responseStatus, 2)
        _ = try await events.next { e -> Bool? in if case let .quickShareRequestEnded(id) = e, id == req.id { return true } else { return nil } }
        XCTAssertTrue(hub.recentTransfers().isEmpty)
    }

    func testNeverModeDeclinesOthersButStillAcceptsThePairedPhone() async throws {
        try await pairAndConnect(name: "Pixel 9")
        hub.setQuickShare(QuickShareSettings(others: .never))
        var s = try await sender(name: "Stranger", texts: [.init(title: "x", type: .text, payloadId: 1, size: 1)])
        XCTAssertEqual(try s.nextSharing().responseStatus, 2, "declined without a prompt")
        XCTAssertFalse(events.all().contains { if case .quickShareRequest = $0 { return true } else { return false } })
        s = try await sender(name: "Pixel 9", texts: [.init(title: "x", type: .text, payloadId: 1, size: 1)])
        XCTAssertEqual(try s.nextSharing().responseStatus, 1)
    }

    func testSameNameWhilePhoneIsNotConnectedIsStillAStranger() async throws {
        try await pairAndConnect(name: "Pixel 9")
        hub.setQuickShare(QuickShareSettings(visibility: .always))
        phone.drop()
        _ = try await events.next { e -> Bool? in if case .sessionClosed = e { return true } else { return nil } }
        let s = try await sender(name: "Pixel 9", texts: [.init(title: "x", type: .text, payloadId: 1, size: 1)])
        let req = try await events.next { e -> QuickShareIncoming? in if case let .quickShareRequest(r) = e { return r } else { return nil } }
        XCTAssertEqual(req.sender, "Pixel 9")
        hub.quickShareRespond(id: req.id, accept: false)
        XCTAssertEqual(try s.nextSharing().responseStatus, 2)
    }

    func testImagesCanGoToThePhotosFolder() async throws {
        try await pairAndConnect(name: "Pixel 9")
        hub.setQuickShare(QuickShareSettings(imagesToPhotosFolder: true))
        let img = Data(repeating: 1, count: 2000), doc = Data(repeating: 2, count: 100)
        let s = try await sender(name: "Pixel 9", files: [.init(name: "IMG_1.jpg", type: 1, payloadId: 1, size: 2000, mimeType: "image/jpeg"),
                                                         .init(name: "notes.txt", type: 5, payloadId: 2, size: 100, mimeType: "text/plain")])
        XCTAssertEqual(try s.nextSharing().responseStatus, 1)
        try s.sendFile(id: 1, data: img)
        try s.sendFile(id: 2, data: doc)
        let done = try await events.next { e -> QuickShareDone? in if case let .quickShareDone(d) = e { return d } else { return nil } }
        let byName = Dictionary(uniqueKeysWithValues: done.files.map { ($0.name, $0) })
        XCTAssertEqual(byName["IMG_1.jpg"]?.url.deletingLastPathComponent().path, dir.appendingPathComponent("Pictures").path)
        XCTAssertEqual(byName["IMG_1.jpg"]?.kind, "photo")
        XCTAssertEqual(byName["notes.txt"]?.url.deletingLastPathComponent().path, dir.appendingPathComponent("Downloads").path)
        XCTAssertEqual(byName["notes.txt"]?.kind, "file")
    }

    func testImagesGoToDownloadsByDefault() async throws {
        try await pairAndConnect(name: "Pixel 9")
        hub.setQuickShare(QuickShareSettings())
        let s = try await sender(name: "Pixel 9", files: [.init(name: "IMG_1.jpg", type: 1, payloadId: 1, size: 20, mimeType: "image/jpeg")])
        _ = try s.nextSharing()
        try s.sendFile(id: 1, data: Data(repeating: 1, count: 20))
        let done = try await events.next { e -> QuickShareDone? in if case let .quickShareDone(d) = e { return d } else { return nil } }
        XCTAssertEqual(done.files[0].url.deletingLastPathComponent().path, dir.appendingPathComponent("Downloads").path)
    }

    func testRequestExpiresAfterThirtySecondsOfSilence() async throws {
        // The 30 s timer lives in the connection and is covered in QSConnectionTests (testNoAnswerTimesOut); here, the Hub side:
        // a request that ends without an answer is announced as ended and can't be answered later.
        try await pairAndConnect(name: "Pixel 9")
        hub.setQuickShare(QuickShareSettings())
        let s = try await sender(name: "Stranger", files: [.init(name: "x.bin", payloadId: 3, size: 10, mimeType: "x/y")])
        let req = try await events.next { e -> QuickShareIncoming? in if case let .quickShareRequest(r) = e { return r } else { return nil } }
        (s.pipe as? TCPPipe)?.close()                        // the sender gives up
        _ = try await events.next { e -> Bool? in if case let .quickShareRequestEnded(id) = e, id == req.id { return true } else { return nil } }
        hub.quickShareRespond(id: req.id, accept: true)      // too late: nothing happens
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(hub.recentTransfers().isEmpty)
    }
}
