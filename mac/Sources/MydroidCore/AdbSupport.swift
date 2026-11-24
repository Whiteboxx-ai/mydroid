import Foundation

// Pure helpers for Mac call audio setup (PROTOCOL.md 8.2) and the helper's control lines (8.3). No processes here.

/// What the phone can do for call audio, probed by the helper.
public enum CallAudioTier: String, Codable, Sendable, Equatable {
    case full, listen, none

    /// The Mac offers the Phone / Mac switch.
    public var canRoute: Bool { self != .none }
    /// The Mac can send its microphone to the call.
    public var canTalk: Bool { self == .full }
}

public enum AudioRoute: String, Sendable, Equatable { case phone, mac }

// MARK: adb output

public struct AdbMdnsService: Equatable, Sendable {
    public var name: String
    public var type: String           // "_adb-tls-pairing._tcp" or "_adb-tls-connect._tcp" (trailing dot removed)
    public var host: String
    public var port: Int
    public var isPairing: Bool { type.hasPrefix("_adb-tls-pairing") }
    public var isConnect: Bool { type.hasPrefix("_adb-tls-connect") }
    public var endpoint: String { "\(host):\(port)" }
}

public enum AdbParsing {
    /// Parses `adb mdns services`. Lines look like `name<TAB>_adb-tls-connect._tcp.<TAB>192.168.1.5:41235`.
    public static func mdnsServices(_ output: String) -> [AdbMdnsService] {
        var out: [AdbMdnsService] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let parts = raw.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard parts.count >= 3, let ti = parts.firstIndex(where: { $0.hasPrefix("_adb") }), ti + 1 < parts.count else { continue }
            let hostPort = parts[ti + 1]
            guard let colon = hostPort.lastIndex(of: ":"), let port = Int(hostPort[hostPort.index(after: colon)...]), port > 0 else { continue }
            var host = String(hostPort[..<colon])
            if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            var type = parts[ti]
            while type.hasSuffix(".") { type.removeLast() }
            out.append(AdbMdnsService(name: parts[..<ti].joined(separator: " "), type: type, host: host, port: port))
        }
        return out
    }

    /// `adb pair` prints "Successfully paired to ..." on success.
    public static func pairSucceeded(_ output: String) -> Bool { output.contains("Successfully paired") }

    /// "connected to 192.168.1.5:41235" or "already connected to ...".
    public static func connectSucceeded(_ output: String) -> Bool {
        let o = output.lowercased()
        return o.contains("connected to") && !o.contains("failed") && !o.contains("cannot")
    }

    public struct Device: Equatable, Sendable { public var serial: String; public var state: String }

    /// Parses `adb devices`.
    public static func devices(_ output: String) -> [Device] {
        output.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let p = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard p.count >= 2 else { return nil }
            return Device(serial: String(p[0]), state: String(p[1]))
        }
    }
}

// MARK: QR pairing

public enum AdbPairing {
    private static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    private static func random(_ n: Int) -> String {
        let bytes = MydroidCrypto.randomBytes(n)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    /// A service name the phone will advertise as `_adb-tls-pairing` once it has scanned the code.
    public static func randomServiceName() -> String { "mydroid-" + random(8) }
    public static func randomPassword() -> String { random(12) }

    /// `WIFI:T:ADB;S:<service>;P:<password>;;`
    public static func qrPayload(service: String, password: String) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;") }
        return "WIFI:T:ADB;S:\(esc(service));P:\(esc(password));;"
    }
}

// MARK: Helper control lines (8.3)

public enum HelperEvent: Equatable, Sendable {
    case tier(CallAudioTier)
    case call(inCall: Bool)
    case routed(to: AudioRoute, error: String?)
    case stats(rxRms: Double, txRms: Double, lost: Int)
}

public enum HelperProtocol {
    /// One JSON line from the helper's stdout, or nil for anything else (the shell prints other noise too).
    public static func parse(line: String) -> HelperEvent? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{"), let d = t.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let ev = o["ev"] as? String else { return nil }
        switch ev {
        case "tier":
            guard let v = (o["tier"] as? String).flatMap(CallAudioTier.init(rawValue:)) else { return nil }
            return .tier(v)
        case "call":
            guard let b = o["inCall"] as? Bool else { return nil }
            return .call(inCall: b)
        case "routed":
            guard let to = (o["to"] as? String).flatMap(AudioRoute.init(rawValue:)) else { return nil }
            return .routed(to: to, error: o["error"] as? String)
        case "stats":
            func num(_ k: String) -> Double { (o[k] as? NSNumber)?.doubleValue ?? 0 }
            return .stats(rxRms: num("rxRms"), txRms: num("txRms"), lost: Int(num("lost")))
        default:
            return nil
        }
    }

    private static func line(_ obj: [String: Any]) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self) + "\n"
    }

    public static func hello(macHost: String, udpPort: UInt16, key: Data) -> String {
        line(["cmd": "hello", "macHost": macHost, "udpPort": Int(udpPort), "key": key.base64EncodedString()])
    }
    public static func route(to: AudioRoute) -> String { line(["cmd": "route", "to": to.rawValue]) }
    public static let quit = line(["cmd": "quit"])
}

/// Identify the app by its nonce file so the helper targets the paired copy, even when both APKs are installed.
public enum CallAudioAndroidPackage: String, CaseIterable, Sendable {
    case current = "com.whiteboxxai.mydroid"
    case legacy = "com.mydroid.android"

    /// The remote shell command that starts the helper (run through `adb shell`, so `$(...)` is evaluated on the phone).
    public var launchCommand: String {
        "CLASSPATH=$(pm path \(rawValue) | cut -d: -f2) app_process / com.mydroid.callbridge.Main"
    }

    /// Where the phone writes the nonce for `adb.verify` (8.2.4).
    public var verifyPath: String { "/sdcard/Android/data/\(rawValue)/files/adb-verify" }
    public var grantCommand: String { "pm grant \(rawValue) android.permission.WRITE_SECURE_SETTINGS" }
    public var revokeCommand: String { "pm revoke \(rawValue) android.permission.WRITE_SECURE_SETTINGS" }
}

/// Splits a byte stream into lines (the helper's stdout arrives in arbitrary chunks).
public struct LineBuffer {
    private var buf = Data()
    public init() {}
    public mutating func append(_ d: Data) -> [String] {
        buf.append(d)
        var out: [String] = []
        while let i = buf.firstIndex(of: 0x0a) {
            out.append(String(decoding: buf[buf.startIndex..<i], as: UTF8.self))
            buf = Data(buf[(i + 1)...])
        }
        if buf.count > 1 << 20 { buf.removeAll() }
        return out
    }
}

/// A restart delay that doubles up to a cap, for relaunching the helper and retrying adb.
public struct Backoff: Sendable {
    public var base: TimeInterval
    public var cap: TimeInterval
    public private(set) var attempts = 0
    public init(base: TimeInterval = 1, cap: TimeInterval = 30) { self.base = base; self.cap = cap }
    public mutating func next() -> TimeInterval {
        defer { attempts += 1 }
        return min(cap, base * pow(2, Double(min(attempts, 10))))
    }
    public mutating func reset() { attempts = 0 }
}
