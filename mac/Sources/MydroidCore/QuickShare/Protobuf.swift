import Foundation

// A tiny protobuf (proto2 wire format) reader and writer, enough for the few Quick Share messages Mydroid
// needs. Adapted in spirit from the protobuf definitions collected in NearDrop (Unlicense, public domain):
// https://github.com/grishka/NearDrop

enum PBError: Error, Equatable {
    case truncated
    case badWireType(UInt8)
    case badVarint
    case lengthOverflow
}

struct PBWriter {
    private(set) var data = Data()

    mutating func rawVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    /// Appends bytes as they are (for fixed-width values and for tests that build malformed input).
    mutating func raw(_ d: Data) { data.append(d) }

    mutating func tag(_ field: Int, wire: UInt8) { rawVarint(UInt64(field) << 3 | UInt64(wire)) }

    mutating func varint(_ field: Int, _ v: UInt64) { tag(field, wire: 0); rawVarint(v) }
    /// int32, int64 and enums. Negative values are sign-extended to ten bytes, as protobuf does.
    mutating func int(_ field: Int, _ v: Int64) { varint(field, UInt64(bitPattern: v)) }
    mutating func bool(_ field: Int, _ v: Bool) { varint(field, v ? 1 : 0) }
    mutating func bytes(_ field: Int, _ d: Data) { tag(field, wire: 2); rawVarint(UInt64(d.count)); data.append(d) }
    mutating func string(_ field: Int, _ s: String) { bytes(field, Data(s.utf8)) }
    mutating func message(_ field: Int, _ encoded: Data) { bytes(field, encoded) }
    /// A repeated varint field in packed form.
    mutating func packedVarints(_ field: Int, _ values: [UInt64]) {
        var inner = PBWriter()
        for v in values { inner.rawVarint(v) }
        bytes(field, inner.data)
    }
}

struct PBField {
    let number: Int
    let wire: UInt8
    /// Varint value, or the raw little-endian value of a fixed32 or fixed64 field.
    let scalar: UInt64
    /// The payload of a length-delimited field.
    let bytes: Data
}

struct PBMessage {
    let fields: [PBField]

    init(_ data: Data) throws {
        var out: [PBField] = []
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            func varint() throws -> UInt64 {
                var result: UInt64 = 0
                var shift: UInt64 = 0
                while true {
                    guard i < b.count else { throw PBError.truncated }
                    let byte = b[i]; i += 1
                    if shift >= 64 { throw PBError.badVarint }
                    result |= UInt64(byte & 0x7f) << shift
                    if byte & 0x80 == 0 { return result }
                    shift += 7
                }
            }
            while i < b.count {
                let key = try varint()
                let number = Int(truncatingIfNeeded: key >> 3)
                let wire = UInt8(key & 7)
                guard number > 0 else { throw PBError.badVarint }
                switch wire {
                case 0:
                    out.append(PBField(number: number, wire: wire, scalar: try varint(), bytes: Data()))
                case 1:
                    guard b.count - i >= 8 else { throw PBError.truncated }
                    var v: UInt64 = 0
                    for k in 0..<8 { v |= UInt64(b[i + k]) << UInt64(8 * k) }
                    i += 8
                    out.append(PBField(number: number, wire: wire, scalar: v, bytes: Data()))
                case 2:
                    let len = try varint()
                    guard len <= UInt64(b.count - i) else { throw PBError.lengthOverflow }
                    out.append(PBField(number: number, wire: wire, scalar: 0, bytes: Data(b[i..<(i + Int(len))])))
                    i += Int(len)
                case 5:
                    guard b.count - i >= 4 else { throw PBError.truncated }
                    var v: UInt64 = 0
                    for k in 0..<4 { v |= UInt64(b[i + k]) << UInt64(8 * k) }
                    i += 4
                    out.append(PBField(number: number, wire: wire, scalar: v, bytes: Data()))
                default:
                    throw PBError.badWireType(wire)
                }
            }
        }
        fields = out
    }

    // For scalars the last occurrence wins, which is what protobuf parsers do.
    private func last(_ n: Int, wire: UInt8) -> PBField? { fields.last { $0.number == n && $0.wire == wire } }

    func has(_ n: Int) -> Bool { fields.contains { $0.number == n } }
    func uint(_ n: Int) -> UInt64? { last(n, wire: 0)?.scalar }
    func int64(_ n: Int) -> Int64? { uint(n).map { Int64(bitPattern: $0) } }
    func int32(_ n: Int) -> Int32? { uint(n).map { Int32(truncatingIfNeeded: $0) } }
    func bool(_ n: Int) -> Bool? { uint(n).map { $0 != 0 } }
    func bytes(_ n: Int) -> Data? { last(n, wire: 2)?.bytes }
    func string(_ n: Int) -> String? { bytes(n).flatMap { String(data: $0, encoding: .utf8) } }
    func message(_ n: Int) throws -> PBMessage? { try bytes(n).map { try PBMessage($0) } }
    func messages(_ n: Int) throws -> [PBMessage] {
        try fields.filter { $0.number == n && $0.wire == 2 }.map { try PBMessage($0.bytes) }
    }
    func repeatedBytes(_ n: Int) -> [Data] { fields.filter { $0.number == n && $0.wire == 2 }.map(\.bytes) }
    /// Repeated varints, packed or not.
    func varints(_ n: Int) throws -> [UInt64] {
        var out: [UInt64] = []
        for f in fields where f.number == n {
            if f.wire == 0 { out.append(f.scalar) }
            else if f.wire == 2 {
                let p = try PBMessagePacked.varints(f.bytes)
                out.append(contentsOf: p)
            }
        }
        return out
    }
}

enum PBMessagePacked {
    static func varints(_ d: Data) throws -> [UInt64] {
        var out: [UInt64] = []
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var pending = false
        for byte in d {
            if shift >= 64 { throw PBError.badVarint }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { out.append(result); result = 0; shift = 0; pending = false } else { shift += 7; pending = true }
        }
        if pending { throw PBError.truncated }
        return out
    }
}
