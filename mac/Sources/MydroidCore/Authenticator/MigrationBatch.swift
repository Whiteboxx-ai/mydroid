import Foundation

// PROTOCOL.md 14.4. Reads just enough of Google Authenticator's `otpauth-migration://` QR codes to follow a multi-part
// export ("2 of 3 scanned"). The `MigrationPayload` protobuf is
//   repeated OtpParameters otp_parameters = 1;   // the secrets: skipped over, never decoded or copied
//   int32 version = 2; int32 batch_size = 3; int32 batch_index = 4; int32 batch_id = 5;
// This file reads fields 2 to 5 and counts field 1. It never builds a Data or String from an account.

/// What a scanned QR code is, as far as the importer cares. Anything else is `.other` and is ignored.
public enum ScanPayload: Equatable, Sendable {
    /// `otpauth-migration://offline?data=...` and what we could tell about its batch.
    case migration(MigrationInfo)
    /// A single `otpauth://totp/...` or `otpauth://hotp/...` code.
    case single
    /// A migration-looking code that can't be read.
    case damaged
    /// Anything else (a website, a Wi-Fi code...).
    case other

    /// Longest payload considered. Real exports are a few KB.
    public static let maxLength = 32 * 1024

    public static func classify(_ raw: String) -> ScanPayload {
        guard raw.utf8.count <= maxLength else { return .other }
        let head = raw.prefix(32).lowercased()
        if head.hasPrefix("otpauth-migration://") {
            guard let info = MigrationInfo(uri: raw) else { return .damaged }
            return .migration(info)
        }
        if head.hasPrefix("otpauth://totp/") || head.hasPrefix("otpauth://hotp/") { return .single }
        return .other
    }
}

/// The batch bookkeeping of one migration QR code. No secrets.
public struct MigrationInfo: Equatable, Sendable {
    /// How many QR codes the export has. 1 when the field is missing (a single-part export).
    public var batchSize: Int
    /// This code's position, from 0.
    public var batchIndex: Int
    /// Identifies one export, so codes from two different exports are never mixed.
    public var batchId: Int64
    /// How many accounts this one code holds (only counted).
    public var accountCount: Int

    public init(batchSize: Int, batchIndex: Int, batchId: Int64, accountCount: Int) {
        self.batchSize = batchSize; self.batchIndex = batchIndex; self.batchId = batchId; self.accountCount = accountCount
    }

    /// nil when the URI isn't a readable migration code.
    public init?(uri: String) {
        guard let data = Self.payload(ofURI: uri), let info = Self.scan(data) else { return nil }
        self = info
    }

    /// The decoded bytes of the `data` query parameter.
    static func payload(ofURI uri: String) -> Data? {
        guard let q = uri.firstIndex(of: "?") else { return nil }
        let query = uri[uri.index(after: q)...]
        for part in query.split(separator: "&") {
            guard part.hasPrefix("data=") else { continue }
            var v = String(part.dropFirst(5))
            if let end = v.firstIndex(of: "#") { v = String(v[..<end]) }
            // Percent-escapes first (%2B, %2F, %3D). A literal "+" that lost its escape arrives as a space.
            v = v.replacingOccurrences(of: "+", with: "%2B")
            guard var b64 = v.removingPercentEncoding else { return nil }
            b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            b64 = b64.filter { !$0.isWhitespace }
            while b64.count % 4 != 0 { b64 += "=" }
            return Data(base64Encoded: b64)
        }
        return nil
    }

    /// Walks the top-level fields. Length-delimited fields are skipped by length; field 1 is only counted.
    static func scan(_ data: Data) -> MigrationInfo? {
        var i = data.startIndex
        let end = data.endIndex
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < end, shift < 70 {
                let b = data[i]; i = data.index(after: i)
                if shift < 64 { result |= UInt64(b & 0x7f) << shift }
                if b & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        var size: Int64?
        var index: Int64?
        var id: Int64?
        var accounts = 0
        while i < end {
            guard let key = varint() else { return nil }
            let field = Int(truncatingIfNeeded: key >> 3)
            switch key & 7 {
            case 0:
                guard let v = varint() else { return nil }
                // int32 values are sign-extended to 64 bits by protobuf; read them back as Int32.
                let signed = Int64(Int32(truncatingIfNeeded: v))
                switch field {
                case 3: size = signed
                case 4: index = signed
                case 5: id = signed
                default: break
                }
            case 2:
                guard let len = varint(), len <= UInt64(data.distance(from: i, to: end)) else { return nil }
                if field == 1 { accounts += 1 }
                i = data.index(i, offsetBy: Int(len))
            case 1:
                guard data.distance(from: i, to: end) >= 8 else { return nil }
                i = data.index(i, offsetBy: 8)
            case 5:
                guard data.distance(from: i, to: end) >= 4 else { return nil }
                i = data.index(i, offsetBy: 4)
            default:
                return nil
            }
        }
        guard accounts > 0 else { return nil }
        return MigrationInfo(batchSize: Int(size ?? 1), batchIndex: Int(index ?? 0), batchId: id ?? 0, accountCount: accounts)
    }
}

/// Follows a camera's stream of detected QR codes until the export is complete. Holds only the URIs it must send, and gives them up
/// (clearing itself) the moment the batch is whole. Repeated frames of the same code are recognised and ignored.
public struct ImportTracker: Sendable {
    public enum Event: Equatable, Sendable {
        /// A new part (or a single code) was taken.
        case accepted(scanned: Int, of: Int)
        /// The same code again: nothing changed.
        case duplicate
        /// Everything needed has been read. The URIs are in the batch order. The tracker is empty again.
        case complete([String])
        /// A code that isn't a Google Authenticator transfer code (or an `otpauth://` one).
        case notForUs
        /// A transfer code that can't be read, or a part number that doesn't fit its export.
        case unreadable
        /// A single `otpauth://` code was shown while a multi-part export was half read.
        case finishBatchFirst
        /// Codes from a different export than the one in progress: started over with this one.
        case restarted(scanned: Int, of: Int)
    }

    public static let maxBatch = 50

    private var batchId: Int64?
    private var size = 0
    private var parts: [Int: String] = [:]

    public init() {}

    public var inProgress: Bool { !parts.isEmpty }
    public var scanned: Int { parts.count }
    public var total: Int { size }

    /// Drops everything held.
    public mutating func reset() { parts.removeAll(); batchId = nil; size = 0 }

    public mutating func ingest(_ raw: String) -> Event {
        switch ScanPayload.classify(raw) {
        case .other: return .notForUs
        case .damaged: return .unreadable
        case .single:
            guard parts.isEmpty else { return .finishBatchFirst }
            return .complete([raw])
        case .migration(let info):
            guard info.batchSize >= 1, info.batchSize <= Self.maxBatch, info.batchIndex >= 0, info.batchIndex < info.batchSize else { return .unreadable }
            if info.batchSize == 1 { reset(); return .complete([raw]) }
            var restarted = false
            if let current = batchId, current != info.batchId || size != info.batchSize {
                reset(); restarted = true
            }
            if parts[info.batchIndex] != nil { return .duplicate }
            batchId = info.batchId
            size = info.batchSize
            parts[info.batchIndex] = raw
            if parts.count == size {
                let ordered = (0..<size).compactMap { parts[$0] }
                reset()
                return .complete(ordered)
            }
            return restarted ? .restarted(scanned: parts.count, of: size) : .accepted(scanned: parts.count, of: size)
        }
    }
}
