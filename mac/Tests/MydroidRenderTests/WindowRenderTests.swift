import XCTest
import SwiftUI
import AppKit
@testable import Mydroid
@testable import MydroidCore

/// Off-screen renders of the full window with fixture data. Only runs when MYDROID_RENDER_DIR is set.
@MainActor
final class WindowRenderTests: XCTestCase {
    private var dir: String? { ProcessInfo.processInfo.environment["MYDROID_RENDER_DIR"] }
    private func ago(_ s: TimeInterval) -> Date { Date().addingTimeInterval(-s) }
    private let min = 60.0, hour = 3600.0, day = 86400.0

    // MARK: Fixture pieces

    nonisolated private func png(_ img: NSImage) -> Data {
        NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    nonisolated private func avatar(_ hue: CGFloat) -> Data {
        png(NSImage(size: NSSize(width: 96, height: 96), flipped: false) { r in
            NSGradient(colors: [NSColor(hue: hue, saturation: 0.45, brightness: 0.95, alpha: 1), NSColor(hue: hue, saturation: 0.7, brightness: 0.7, alpha: 1)])!.draw(in: r, angle: 60)
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: 33, y: 52, width: 30, height: 30)).fill()
            NSBezierPath(ovalIn: NSRect(x: 18, y: -22, width: 60, height: 62)).fill()
            return true
        })
    }

    nonisolated private func appIcon(_ hue: CGFloat) -> Data { avatar(hue) }

    /// A landscape-ish picture with a gradient sky, a sun and some hills. Deterministic for a seed.
    nonisolated private func fakePhoto(_ seed: Int, size: NSSize = NSSize(width: 256, height: 192)) -> NSImage {
        NSImage(size: size, flipped: false) { r in
            let h = CGFloat((seed * 37) % 100) / 100
            NSGradient(colors: [NSColor(hue: h, saturation: 0.35, brightness: 0.98, alpha: 1), NSColor(hue: (h + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.85, alpha: 1)])!.draw(in: r, angle: 90)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.width * CGFloat(0.2 + Double(seed % 5) * 0.12), y: r.height * 0.55, width: r.height * 0.22, height: r.height * 0.22)).fill()
            for k in 0..<3 {
                NSColor(hue: (h + 0.4 + CGFloat(k) * 0.05).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.55 - CGFloat(k) * 0.1, alpha: 1).setFill()
                let p = NSBezierPath()
                p.move(to: NSPoint(x: 0, y: 0))
                p.line(to: NSPoint(x: 0, y: r.height * (0.25 + CGFloat(k) * 0.06)))
                p.curve(to: NSPoint(x: r.width, y: r.height * (0.2 + CGFloat((seed + k) % 3) * 0.08)),
                        controlPoint1: NSPoint(x: r.width * 0.3, y: r.height * (0.5 - CGFloat(k) * 0.1)), controlPoint2: NSPoint(x: r.width * 0.7, y: r.height * 0.05))
                p.line(to: NSPoint(x: r.width, y: 0)); p.close(); p.fill()
            }
            return true
        }
    }

    nonisolated private func jpeg(_ img: NSImage) -> Data {
        NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!
    }

    private func baseState(link: LinkState = .connected, sms: Bool = true) -> HubState {
        var st = HubState()
        st.link = link
        st.phone = PhoneInfo(name: "Pixel 9", model: "Pixel 9", battery: 78, charging: false, network: .wifi)
        st.lastSeen = ago(14 * min)
        st.settings.smsHistory = sms
        st.settings.calls = true
        st.settings.photos = true
        st.features.photos = .on; st.features.calls = .on; st.features.notifications = .on
        return st
    }

    private func conv(_ title: String, group: Bool, _ msgs: [(String, String, TimeInterval)], avatarHue: CGFloat? = nil) -> Conversation {
        Conversation(title: title, isGroup: group, messages: msgs.map { ConversationMessage(sender: $0.0, text: $0.1, when: ago($0.2)) },
                     avatar: avatarHue.map(avatar))
    }

    /// Builds the model with SMS threads and app conversations.
    private func messagesModel(state: HubState? = nil, select: ChatID? = nil) -> AppModel {
        let m = AppModel(fixture: state ?? baseState())
        let ms = m.messages
        ms.smsEnabled = true
        ms.threadsLoaded = true
        ms.threads = [
            SmsThread(id: "11", addresses: ["+91 98765 43210"], name: "Maya Tan", snippet: "Are we still on for coffee tomorrow?", date: ago(4 * min), unread: 2, avatar: avatar(0.56)),
            SmsThread(id: "12", addresses: ["HDFCBK"], name: "HDFCBK", snippet: "A/c XX4821 debited Rs 2,400.00 at Blue Tokai on 22-Nov. Avl bal Rs 41,318.22", date: ago(52 * min), unread: 0),
            SmsThread(id: "13", addresses: ["+91 99001 12233", "+91 98450 77881", "+91 90080 44556"], name: "Sunday hike", snippet: "Karthik: I'll bring the snacks", date: ago(3 * hour), unread: 0),
            SmsThread(id: "14", addresses: ["+91 98110 22334"], name: "Mom", snippet: "Call me when you land \u{2764}\u{FE0F}", date: ago(1 * day + 2 * hour), unread: 1, avatar: avatar(0.0)),
            SmsThread(id: "15", addresses: ["+91 70000 11122"], name: "Priya Nair", snippet: "Standup moved to 11:30, same room", date: ago(1 * day + 5 * hour), unread: 0, avatar: avatar(0.78)),
            SmsThread(id: "16", addresses: ["SWIGGY"], name: "Swiggy", snippet: "Your order is on the way! Track it in the app.", date: ago(2 * day), unread: 0),
            SmsThread(id: "17", addresses: ["+91 80123 45678"], name: "Dr. Rao's Clinic", snippet: "Reminder: your appointment is on Tue, 4:30 PM. Reply C to confirm.", date: ago(4 * day), unread: 0),
            SmsThread(id: "18", addresses: ["+91 91234 56780"], name: "+91 91234 56780", snippet: "Delivery attempted. Reschedule at the link below.", date: ago(9 * day), unread: 0),
        ]
        ms.messagesByThread["11"] = [
            SmsMessage(id: "1", from: "+91 98765 43210", body: "Hey! Did you see the new place on 12th Main?", date: ago(1 * day + 3 * hour), out: false),
            SmsMessage(id: "2", from: "", body: "Not yet. Is it the one with the green door?", date: ago(1 * day + 3 * hour - 2 * min), out: true),
            SmsMessage(id: "3", from: "+91 98765 43210", body: "That's the one. They do a really good flat white", date: ago(1 * day + 3 * hour - 3 * min), out: false),
            SmsMessage(id: "4", from: "+91 98765 43210", body: "Want to try it tomorrow?", date: ago(1 * day + 3 * hour - 3 * min - 20), out: false),
            SmsMessage(id: "5", from: "", body: "Yes, let's do it", date: ago(1 * day + 2 * hour), out: true),
            SmsMessage(id: "6", from: "", body: "10:30 works for me. I'll bring the laptop in case we end up working", date: ago(1 * day + 2 * hour - 40), out: true),
            SmsMessage(id: "7", from: "+91 98765 43210", body: "Perfect \u{1F44D}", date: ago(20 * hour), out: false),
            SmsMessage(id: "8", from: "+91 98765 43210", body: "Are we still on for coffee tomorrow?", date: ago(4 * min), out: false),
            SmsMessage(id: "9", from: "+91 98765 43210", body: "I can do 11 instead if that's easier", date: ago(3 * min), out: false),
        ]
        ms.moreByThread["11"] = true
        ms.pending = [PendingSend(id: "c1", threadId: "11", to: ["+91 98765 43210"], text: "11 is fine, see you there", date: ago(20), state: .sending)]
        ms.messagesByThread["13"] = [
            SmsMessage(id: "21", from: "+91 99001 12233", body: "Meeting at the trailhead at 6:15?", date: ago(5 * hour), out: false),
            SmsMessage(id: "22", from: "", body: "Works for me", date: ago(4 * hour + 40 * min), out: true),
            SmsMessage(id: "23", from: "+91 98450 77881", body: "Karthik: I'll bring the snacks", date: ago(3 * hour), out: false),
        ]

        // App conversations, built the way the app builds them: from notification payloads over time.
        func post(_ key: String, _ pkg: String, _ app: String, _ c: Conversation, icon: Data?, canReply: Bool = true, live: Bool) {
            let n = PhoneNotification(key: key, pkg: pkg, app: app, title: c.title, text: c.messages.last?.text ?? "", when: c.messages.last?.when ?? Date(),
                                      canReply: canReply, icon: icon, category: .message, conversation: c)
            ms.history.record(n)
            if live { ms.live.append(n) }
        }
        let wa = appIcon(0.36), tg = appIcon(0.55)
        post("wa1", "com.whatsapp", "WhatsApp", conv("Goa trip", group: true, [
            ("Maya", "Are we still doing the 14th?", 3 * hour + 9 * min), ("Maya", "Flights are cheaper on Friday", 3 * hour + 7 * min),
            ("", "Yes, 14th works for me", 3 * hour), ("Dev", "Same. Found a villa with a pool", 2 * hour + 30 * min), ("Dev", "booking the villa now", 2 * hour + 29 * min)]), icon: wa, live: false)
        post("wa1", "com.whatsapp", "WhatsApp", conv("Goa trip", group: true, [
            ("Dev", "booking the villa now", 2 * hour + 29 * min), ("Dev", "It's 18k for the 4 nights, split 6 ways", 2 * hour + 28 * min),
            ("Ananya", "that's way under what I expected", 2 * hour + 25 * min), ("", "Nice find! Send the link?", 2 * hour + 20 * min),
            ("Dev", "Sending in a sec", 40 * min), ("Ananya", "Also, who's driving from the airport?", 9 * min)]), icon: wa, live: true)
        post("tg1", "org.telegram.messenger", "Telegram", conv("Ananya", group: false, [
            ("Ananya", "did you get a chance to look at the deck?", 6 * hour), ("", "Looking at it tonight", 5 * hour + 50 * min),
            ("Ananya", "no rush, thanks!", 5 * hour + 49 * min)], avatarHue: 0.9), icon: tg, live: false)
        post("wa2", "com.whatsapp", "WhatsApp", conv("Rohan", group: false, [
            ("Rohan", "bro are you coming Saturday", 1 * day + 6 * hour), ("Rohan", "we need a 5th for padel", 1 * day + 6 * hour - 30)], avatarHue: 0.12), icon: wa, live: false)
        ms.sendError = [:]
        if let select { ms.selection = select }
        return m
    }

    // MARK: Rendering

    private func renderWindow<V: View>(_ name: String, _ scheme: ColorScheme, size: CGSize, spins: Int = 12, _ content: V) throws {
        guard let dir else { throw XCTSkip("MYDROID_RENDER_DIR not set") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: content)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        win.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<spins { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap for \(name)") }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("png failed for \(name)") }
        try png.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }

    private let winSize = CGSize(width: 1120, height: 720)

    private func shot(_ name: String, _ build: @MainActor () -> AppModel) throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        for scheme in [ColorScheme.light, .dark] {
            let m = build()
            // NavigationSplitView's sidebar doesn't draw off-screen, so lay out the same two views by hand.
            let content = HStack(spacing: 0) {
                SidebarView().frame(width: 208)
                Divider()
                MainDetailView()
            }
            try renderWindow(name, scheme, size: winSize, content.frame(width: winSize.width, height: winSize.height).environment(m).environment(m.ui).environment(\.controlActiveState, .key))
        }
    }

    func testMessages() throws {
        try shot("window-messages-sms") { let m = messagesModel(select: .sms("11")); m.section = .messages; return m }
        try shot("window-messages-whatsapp-group") {
            let id = ConversationHistory.conversationID(pkg: "com.whatsapp", title: "Goa trip")
            let m = messagesModel(select: .app(id)); m.section = .messages; return m
        }
        try shot("window-messages-sms-group") { let m = messagesModel(select: .sms("13")); m.section = .messages; return m }
        try shot("window-messages-new") { let m = messagesModel(); m.messages.composingNew = true; m.messages.newRecipients = "ma"; return m }
        try shot("window-messages-permission") {
            let m = AppModel(fixture: baseState())
            m.messages.smsEnabled = true; m.messages.permissionDenied = true
            return m
        }
        try shot("window-messages-off") { AppModel(fixture: baseState(sms: false)) }
        try shot("window-messages-search") {
            let m = messagesModel(select: .sms("11")); m.messages.query = "villa"; return m
        }
    }

    func testPopoverFooter() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        for scheme in [ColorScheme.light, .dark] {
            let m = messagesModel()
            let view = VStack(spacing: 0) { HeaderView(); Divider().opacity(0.5); FooterView() }
                .frame(width: 372).background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
            try renderWindow("popover-open-mydroid", scheme, size: CGSize(width: 372, height: 130), view.environment(m))
        }
    }

    func testDisconnected() throws {
        try shot("window-disconnected") {
            var st = baseState(link: .searching); st.phone?.battery = nil
            let m = AppModel(fixture: st); m.section = .messages; return m
        }
        try shot("window-disconnected-cached") {
            let m = messagesModel(state: baseState(link: .searching), select: .sms("11")); return m
        }
    }

    func testPhotos() throws {
        try XCTSkipIf(dir == nil, "MYDROID_RENDER_DIR not set")
        func build(preview: Bool) -> AppModel {
            let m = AppModel(fixture: baseState())
            m.section = .photos
            let p = m.photos
            var items: [PhotoItem] = []
            let sizes: [(Int, Int)] = [(4000, 3000), (3000, 4000), (4000, 3000), (4032, 2268), (3000, 3000)]
            for i in 0..<96 {
                let wh = sizes[i % sizes.count]
                let taken = ago(Double(i) * 0.7 * day + Double(i % 7) * hour)
                items.append(PhotoItem(id: WireID("\(5000 - i)", numeric: true), name: String(format: "IMG_%04d.jpg", 4821 - i), taken: taken, width: wh.0, height: wh.1,
                                       size: Int64(2_400_000 + i * 13_000), mime: "image/jpeg", album: i % 6 == 0 ? "screenshots" : "camera"))
            }
            p.albums[.all] = AlbumState(items: items, more: true, loading: false, loaded: true)
            for it in items {
                let w = it.width >= it.height ? 256 : 192, h = it.width >= it.height ? 192 : 256
                p.cacheThumb(fakePhoto(Int(it.id.text) ?? 1, size: NSSize(width: w, height: h)), id: it.id.text)
            }
            p.selection = Set(items.prefix(4).dropFirst().map { $0.id.text })
            if preview {
                let it = items[2]
                // The "downloaded" original, put where the Hub caches it.
                let url = m.hub.libraryFile(id: it.id, name: it.name)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? jpeg(fakePhoto(7, size: NSSize(width: 1600, height: 1200))).write(to: url)
                p.previewID = it.id.text
                p.selection = [it.id.text]
            }
            return m
        }
        try shot("window-photos-grid") { build(preview: false) }
        try shot("window-photos-preview") { build(preview: true) }
        try shot("window-photos-permission") {
            var st = baseState(); st.features.photos = .needsPermission
            let m = AppModel(fixture: st); m.section = .photos; return m
        }
        try shot("window-photos-loading") {
            let m = AppModel(fixture: baseState()); m.section = .photos
            m.photos.albums[.all] = AlbumState(items: [], more: true, loading: true, loaded: false); return m
        }
    }

    func testCalls() throws {
        try shot("window-calls") {
            let m = AppModel(fixture: baseState())
            m.section = .calls
            let c = m.calls
            c.loaded = true
            c.records = [
                CallRecord(number: "+91 98765 43210", name: "Maya Tan", kind: .missed, date: ago(25 * min)),
                CallRecord(number: "+91 98110 22334", name: "Mom", kind: .outgoing, date: ago(2 * hour), duration: 612),
                CallRecord(number: "+91 80123 45678", name: "Dr. Rao's Clinic", kind: .incoming, date: ago(5 * hour), duration: 94),
                CallRecord(number: "+91 99887 76655", name: "", kind: .rejected, date: ago(1 * day + 1 * hour)),
                CallRecord(number: "+91 70000 11122", name: "Priya Nair", kind: .incoming, date: ago(1 * day + 4 * hour), duration: 1544),
                CallRecord(number: "+91 99001 12233", name: "Karthik", kind: .outgoing, date: ago(2 * day), duration: 47),
                CallRecord(number: "+91 91234 56780", name: "", kind: .missed, date: ago(3 * day)),
                CallRecord(number: "+91 98450 77881", name: "Rohan", kind: .incoming, date: ago(5 * day), duration: 3725),
                CallRecord(number: "+91 98765 43210", name: "Maya Tan", kind: .outgoing, date: ago(6 * day), duration: 211),
                CallRecord(number: "+91 80000 99911", name: "Airtel", kind: .incoming, date: ago(8 * day), duration: 38),
            ]
            c.number = "98765 4"
            c.selection = c.records[1].id
            return m
        }
        try shot("window-calls-dialing") {
            let m = AppModel(fixture: baseState()); m.section = .calls
            m.calls.loaded = true
            m.calls.records = [CallRecord(number: "+91 98765 43210", name: "Maya Tan", kind: .missed, date: ago(25 * min))]
            m.calls.number = "+91 98765 43210"; m.calls.note = "Calling on your phone"
            return m
        }
        try shot("window-calls-permission") {
            var st = baseState(); st.features.calls = .needsPermission
            let m = AppModel(fixture: st); m.section = .calls; return m
        }
    }

    func testFiles() throws {
        try shot("window-files") {
            let m = AppModel(fixture: baseState())
            m.section = .files
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-files-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            func photo(_ name: String, _ seed: Int) -> URL {
                let u = tmp.appendingPathComponent(name); try? jpeg(fakePhoto(seed, size: NSSize(width: 640, height: 480))).write(to: u); return u
            }
            func file(_ name: String) -> URL { let u = tmp.appendingPathComponent(name); try? Data("x".utf8).write(to: u); return u }
            m.files.received = [
                SavedFile(xid: "photo:1:1", kind: "photo", url: photo("IMG_4821.jpg", 3), name: "IMG_4821.jpg", size: 3_212_004, taken: ago(6 * min), savedAt: ago(5 * min)),
                SavedFile(xid: "photo:2:1", kind: "photo", url: photo("IMG_4820.jpg", 8), name: "IMG_4820.jpg", size: 2_870_211, taken: ago(2 * hour), savedAt: ago(2 * hour)),
                SavedFile(xid: "file:3", kind: "file", url: file("Boarding pass - GOI.pdf"), name: "Boarding pass - GOI.pdf", size: 184_220, taken: nil, savedAt: ago(5 * hour)),
                SavedFile(xid: "photo:4:1", kind: "photo", url: photo("Screenshot_20261121-181133.png", 12), name: "Screenshot_20261121-181133.png", size: 912_330, taken: ago(1 * day), savedAt: ago(1 * day)),
                SavedFile(xid: "file:5", kind: "file", url: file("contract-v3-signed.pdf"), name: "contract-v3-signed.pdf", size: 1_204_881, taken: nil, savedAt: ago(2 * day)),
                SavedFile(xid: "photo:6:1", kind: "photo", url: tmp.appendingPathComponent("gone.jpg"), name: "IMG_4790.jpg", size: 2_100_000, taken: ago(4 * day), savedAt: ago(4 * day)),
            ]
            m.files.sent = [
                SentRecord(xid: "file:s1", name: "Trip itinerary.pdf", size: 402_100, date: ago(3 * hour), path: file("Trip itinerary.pdf").path, failed: nil),
                SentRecord(xid: "file:s2", name: "invoice-nov.xlsx", size: 88_000, date: ago(1 * day + 2 * hour), path: file("invoice-nov.xlsx").path, failed: "Phone disconnected"),
            ]
            m.files.active = [TransferProgress(xid: "file:live", name: "Keynote-final.key", kind: "file", outgoing: true, done: 31_000_000, total: 74_000_000)]
            return m
        }
        try shot("window-files-empty") { let m = AppModel(fixture: baseState()); m.section = .files; return m }
    }
}
