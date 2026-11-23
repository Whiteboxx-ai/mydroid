import Foundation

public enum CodecError: Error { case malformed(String) }

/// A decoded protocol message: JSON header fields plus optional binary payload (PROTOCOL.md 4.3).
public struct Message: @unchecked Sendable {
    public var type: String
    public var fields: [String: Any]
    public var payload: Data

    public init(_ type: String, _ fields: [String: Any] = [:], payload: Data = Data()) {
        self.type = type
        self.fields = fields
        self.payload = payload
    }

    public func string(_ k: String) -> String? { fields[k] as? String }
    public func int(_ k: String) -> Int64? {
        guard let n = fields[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.int64Value
    }
    public func bool(_ k: String) -> Bool? { fields[k] as? Bool }
    public func array(_ k: String) -> [[String: Any]]? { fields[k] as? [[String: Any]] }

    public func encode() throws -> Data {
        var header = fields
        header["t"] = type
        let json = try JSONSerialization.data(withJSONObject: header, options: [.withoutEscapingSlashes, .sortedKeys])
        var out = Data()
        var h = UInt32(json.count).bigEndian
        withUnsafeBytes(of: &h) { out.append(contentsOf: $0) }
        out.append(json)
        out.append(payload)
        return out
    }

    public static func decode(_ data: Data) throws -> Message {
        let data = Data(data)
        guard data.count >= 4 else { throw CodecError.malformed("short") }
        let h = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Int(h) <= data.count - 4 else { throw CodecError.malformed("header length") }
        let json = data.subdata(in: 4..<(4 + Int(h)))
        guard var obj = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let t = obj.removeValue(forKey: "t") as? String
        else { throw CodecError.malformed("header") }
        return Message(t, obj, payload: data.subdata(in: (4 + Int(h))..<data.count))
    }
}

/// Length-prefixed framing: u32 BE length followed by the body. Max 1 MiB.
public enum Framing {
    public static let maxFrame = 1 << 20

    public static func wrap(_ body: Data) -> Data {
        var out = Data(capacity: body.count + 4)
        var n = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }
}

public struct FrameBuffer {
    private var buf = Data()
    public init() {}

    public enum Failure: Error { case tooLarge }

    public mutating func append(_ d: Data) { buf.append(d) }

    /// Next complete frame body, or nil if more bytes are needed.
    public mutating func next() throws -> Data? {
        guard buf.count >= 4 else { return nil }
        let s = buf.startIndex
        let len = Int(buf[s]) << 24 | Int(buf[s + 1]) << 16 | Int(buf[s + 2]) << 8 | Int(buf[s + 3])
        if len > Framing.maxFrame { throw Failure.tooLarge }
        guard buf.count >= 4 + len else { return nil }
        let body = Data(buf[(s + 4)..<(s + 4 + len)])
        buf = Data(buf.dropFirst(4 + len))
        return body
    }
}

extension Message {
    /// A JSON number as a finite Double (accepts integers). Booleans and non-finite values are nil.
    public func double(_ k: String) -> Double? {
        guard let n = fields[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }
}
