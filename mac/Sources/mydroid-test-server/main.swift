import Foundation
import MydroidCore

// Headless interop driver for PROTOCOL.md section 6. Uses the same Hub (Server, pairing, transfer
// engine, ledger) as the Mydroid app; only the storage is file-based and the "user" is automatic.

setvbuf(stdout, nil, _IOLBF, 0)

func say(_ s: String) { print(s); fflush(stdout) }

var dataPath: String?
var port: UInt16 = Server.defaultPort
var bonjour = false
var argv = CommandLine.arguments.dropFirst()
while let a = argv.popFirst() {
    switch a {
    case "--data": dataPath = argv.popFirst()
    case "--port": port = argv.popFirst().flatMap(UInt16.init) ?? port
    case "--bonjour": bonjour = true
    case "-h", "--help":
        say("usage: mydroid-test-server --data <dir> [--port N] [--bonjour]"); exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument \(a)\n".utf8)); exit(2)
    }
}
guard let dataPath else {
    FileHandle.standardError.write(Data("usage: mydroid-test-server --data <dir> [--port N]\n".utf8)); exit(2)
}
let dataDir = URL(fileURLWithPath: dataPath, isDirectory: true)
try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

final class Smoke {
    let hub: Hub
    let dataDir: URL
    var step = 2
    // step 3
    var gotStatus = false, gotFeatures = false, gotSnapshot = false
    // step 4
    var gotResult = false, gotRemoved = false
    // step 6
    var closedInStep6 = false, resumeChecked = false
    // step 10
    var gotPong = false
    var finished = false

    init(hub: Hub, dataDir: URL) { self.hub = hub; self.dataDir = dataDir }

    func fail(_ reason: String) -> Never {
        say("SMOKE FAIL \(reason)")
        exit(1)
    }
    func ok(_ n: Int) { say("STEP \(n) ok"); step = n + 1 }

    /// Called on the hub queue.
    func handle(_ e: HubEvent) {
        switch e {
        case let .confirmCode(code, _):
            say("CONFIRM \(code)")
            hub.confirmPairing()
        case .sessionClosed:
            if step == 6 { closedInStep6 = true }
        case let .message(m):
            handleMessage(m)
        case let .notificationResult(key, okay, error):
            guard step == 4, key == "k1" else { return }
            if !okay { fail("notif.result not ok: \(error ?? "")") }
            gotResult = true; checkStep4()
        case let .notificationRemoved(key):
            guard step == 4, key == "k1" else { return }
            gotRemoved = true; checkStep4()
        case let .offer(xid, outcome):
            if step == 6, xid == "photo:2:100", closedInStep6, case let .accept(offset) = outcome {
                if offset != 262144 { fail("resume offset \(offset), expected 262144") }
                resumeChecked = true
            }
            if step == 7, xid == "photo:1:100" {
                guard outcome == .skip else { fail("duplicate photo:1:100 was not skipped") }
                ok(7)
                sendHello()
            }
        case let .received(f):
            if step == 5, f.xid == "photo:1:100" {
                guard f.url.path.hasPrefix(dataDir.appendingPathComponent("Pictures").path),
                      FileManager.default.fileExists(atPath: f.url.path) else { fail("photo 1 not in <data>/Pictures") }
                ok(5)
            } else if step == 6, f.xid == "photo:2:100" {
                guard resumeChecked else { fail("photo 2 finished without a resumed offer") }
                ok(6)
            }
        case let .transferFailed(xid, error):
            fail("transfer \(xid) failed: \(error)")
        case let .sent(_, name, skipped):
            guard step == 8, name == "hello.txt" else { return }
            if skipped { fail("hello.txt was skipped") }
            ok(8)
        case let .sendFailed(_, name, error):
            fail("sending \(name) failed: \(error)")
        case let .clipboard(text):
            guard step == 9 else { return }
            if text != "hello from phone" { fail("clipboard text was \"\(text)\"") }
            hub.sendClipboard("hello from mac")
            ok(9)
            hub.sendPing()
        default: break
        }
    }

    func handleMessage(_ m: Message) {
        switch (step, m.type) {
        case (2, "bye"):
            ok(2)
        case (3, "device.status"):
            guard m.int("battery") == 78, m.string("network") == "wifi" else { fail("device.status mismatch") }
            gotStatus = true; checkStep3()
        case (3, "feature.status"):
            for k in ["notifications", "photos", "calls", "clipboard"] where m.string(k) != "on" { fail("feature.status \(k) != on") }
            guard m.bool("backgroundRestricted") == false else { fail("backgroundRestricted should be false") }
            gotFeatures = true; checkStep3()
        case (3, "notif.snapshot"):
            guard (m.array("items") ?? []).isEmpty else { fail("snapshot not empty") }
            gotSnapshot = true; checkStep3()
        case (4, "notif.posted"):
            guard m.string("key") == "k1", m.string("app") == "Messages", m.string("title") == "Maya Tan",
                  m.string("text") == "Are we still on for coffee?", m.bool("canReply") == true
            else { fail("notif.posted k1 mismatch") }
            hub.reply(key: "k1", text: "On my way")
        case (10, "pong"):
            gotPong = true
        case (10, "bye"):
            guard gotPong else { fail("bye before pong") }
            say("STEP 10 ok")
            say("SMOKE OK")
            exit(0)
        default: break
        }
    }

    func checkStep3() { if gotStatus && gotFeatures && gotSnapshot { ok(3) } }
    func checkStep4() { if gotResult && gotRemoved { ok(4) } }

    func sendHello() {
        let dir = dataDir.appendingPathComponent("outgoing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("hello.txt")
        try? Data("hello from mac\n".utf8).write(to: url)
        hub.sendFile(url, xid: "file:" + UUID().uuidString.lowercased())
    }
}

let store = FileKeyValueStore(directory: dataDir.appendingPathComponent("state"))
let hub = Hub(HubConfiguration(
    macName: Host.current().localizedName ?? "Mac",
    identity: Identity(store: store), config: store,
    ledgerURL: dataDir.appendingPathComponent("ledger.json"),
    photosDirectory: dataDir.appendingPathComponent("Pictures", isDirectory: true),
    downloadsDirectory: dataDir.appendingPathComponent("Downloads", isDirectory: true),
    preferredPort: port, advertiseBonjour: bonjour))
let smoke = Smoke(hub: hub, dataDir: dataDir)
hub.onEvent = { smoke.handle($0) }

guard hub.startAndWait() != nil else { smoke.fail("could not listen") }
hub.setSettings(.all)
hub.startPairing()
var url: String?
for _ in 0..<250 { url = hub.pairURL; if url != nil { break }; Thread.sleep(forTimeInterval: 0.02) }
guard let url else { smoke.fail("no pairing URL") }
say("PAIR_URL \(url)")
say("STEP 1 ok")

DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
    smoke.fail("timeout at step \(smoke.step)")
}
signal(SIGTERM) { _ in exit(130) }
dispatchMain()
