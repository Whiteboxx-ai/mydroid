import Foundation
import MydroidNM

// mydroid-nmhost: the helper Chrome starts for the Mydroid authenticator extension (PROTOCOL.md 14.3).
// It speaks Chrome's native messaging on stdin/stdout and relays each request to the running Mydroid app over
// ~/Library/Application Support/Mydroid/otp.sock. It holds no secrets and logs nothing about requests.
// If Mydroid isn't running it starts it (`open -b com.mydroid.mac`) and retries for a few seconds.

setvbuf(stdout, nil, _IOFBF, 0)
let args = CommandLine.arguments
let env = ProcessInfo.processInfo.environment
// Chrome passes the calling extension's origin as the first argument; anything else is refused.
if env["MYDROID_NM_ALLOW_ANY_ORIGIN"] != "1" && !NativeMessaging.isAllowed(origin: args.count > 1 ? args[1] : nil) {
    FileHandle.standardError.write(Data("mydroid-nmhost: not started by the Mydroid extension\n".utf8))
    exit(2)
}

let socketPath = OTPSocket.defaultPath()
let allowedOps: Set<String> = ["code", "list", "link", "status", "autofill", "hello"]
let outLock = NSLock()

func writeToBrowser(_ object: [String: Any]) {
    guard let framed = NativeMessaging.frame(object: object) else { return }
    outLock.lock(); defer { outLock.unlock() }
    FileHandle.standardOutput.write(framed)
}

let launchLock = NSLock()
var launched = false
func launchApp() {
    launchLock.lock(); defer { launchLock.unlock() }
    guard !launched else { return }
    launched = true
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", "-b", OTPSocket.launchBundleID]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
}

func relay(_ original: Data) {
    var body = original
    guard let req = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
        writeToBrowser(["ok": false, "error": "bad_request"]); return
    }
    var base: [String: Any] = [:]
    if let id = req["id"] { base["id"] = id }
    guard let op = req["op"] as? String, allowedOps.contains(op) else {
        base["ok"] = false; base["error"] = "bad_request"; writeToBrowser(base); return
    }
    var isHello = false
    if op == "hello" {
        // Say which browser started us (its own executable), so Arc isn't mistaken for Chrome. A hello never launches the app.
        isHello = true
        var obj = req
        if let p = ParentProcess.executablePath() { obj["parent"] = p } else { obj.removeValue(forKey: "parent") }
        body = (try? JSONSerialization.data(withJSONObject: obj)) ?? original
    }
    do {
        let reply = isHello ? try OTPSocket.request(path: socketPath, payload: body, timeout: 10)
                            : try OTPSocket.request(path: socketPath, payload: body, timeout: 50, launch: launchApp, launchWait: 8)
        if var obj = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] {
            if let id = req["id"] { obj["id"] = id }
            writeToBrowser(obj)
        } else {
            base["ok"] = false; base["error"] = "bad_reply"; writeToBrowser(base)
        }
    } catch OTPSocket.Failure.noServer {
        base["ok"] = false; base["error"] = "no_app"; writeToBrowser(base)
    } catch OTPSocket.Failure.timeout {
        base["ok"] = false; base["error"] = "timeout"; writeToBrowser(base)
    } catch {
        base["ok"] = false; base["error"] = "no_app"; writeToBrowser(base)
    }
}

var decoder = NativeMessaging.FrameDecoder()
let stdin = FileHandle.standardInput
while true {
    let chunk = stdin.availableData
    if chunk.isEmpty { break }                       // the browser closed the port
    decoder.append(chunk)
    do {
        while let body = try decoder.next() {
            Thread.detachNewThread { relay(body) }   // each request on its own thread: a slow approval never blocks the next one
        }
    } catch {
        exit(1)                                      // an oversized frame means the stream is not trustworthy
    }
}
// Let in-flight replies finish briefly; the browser is gone, so there is nobody to answer.
exit(0)
