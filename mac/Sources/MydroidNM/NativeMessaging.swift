import Foundation

/// Chrome native messaging for the Mydroid authenticator (PROTOCOL.md 14.3).
public enum NativeMessaging {
    public static let hostName = "com.mydroid.otp"
    /// The extension's fixed ID, derived from the `key` in `extension/manifest.json` (a test checks they agree).
    public static let extensionID = "mgcbfndjnaceidpgamoffmgkljhlmheb"
    public static var allowedOrigin: String { "chrome-extension://\(extensionID)/" }
    /// The most Chrome accepts from a host in one message.
    public static let maxToBrowser = 1 << 20
    /// What this host accepts from the browser (requests are tiny).
    public static let maxFromBrowser = 1 << 20

    /// Chrome's framing: a u32 length in the machine's native byte order (little-endian on every Mac) then that many bytes of UTF-8 JSON.
    public static func frame(_ json: Data) -> Data {
        var out = Data(capacity: json.count + 4)
        var n = UInt32(json.count).littleEndian
        withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
        out.append(json)
        return out
    }

    public static func frame(object: [String: Any]) -> Data? {
        guard let d = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), d.count <= maxToBrowser else { return nil }
        return frame(d)
    }

    public struct FrameDecoder {
        public enum Failure: Error, Equatable { case tooLarge(Int) }
        private var buffer = Data()
        public init() {}
        public mutating func append(_ d: Data) { buffer.append(d) }
        /// The next complete message body, or nil while more bytes are needed.
        public mutating func next() throws -> Data? {
            guard buffer.count >= 4 else { return nil }
            let s = buffer.startIndex
            let len = Int(buffer[s]) | Int(buffer[s + 1]) << 8 | Int(buffer[s + 2]) << 16 | Int(buffer[s + 3]) << 24
            if len > NativeMessaging.maxFromBrowser { throw Failure.tooLarge(len) }
            guard buffer.count >= 4 + len else { return nil }
            let body = Data(buffer[(s + 4)..<(s + 4 + len)])
            buffer = Data(buffer.dropFirst(4 + len))
            return body
        }
    }

    /// Whether Chrome's first argument (the calling origin) is our extension.
    public static func isAllowed(origin: String?) -> Bool { origin == allowedOrigin }
}

#if canImport(Darwin)
import Darwin

/// The program that started this helper: the browser. Only its path is read.
public enum ParentProcess {
    public static func executablePath() -> String? {
        var buf = [CChar](repeating: 0, count: 4096)      // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(getppid(), &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }
}
#endif
