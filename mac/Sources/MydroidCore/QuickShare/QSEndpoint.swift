import Foundation

public enum QSDeviceType: Int, Sendable {
    case unknown = 0, phone = 1, tablet = 2, laptop = 3, car = 4, foldable = 5, xr = 6

    public var isPhone: Bool { self == .phone || self == .foldable }
}

/// How a Quick Share receiver shows up on the network (NearDrop's PROTOCOL.md, "How devices find each other").
public enum QSEndpoint {
    /// The mDNS service type: the first six bytes of SHA256("NearbySharing"), upper-case hex.
    public static let serviceType = "_FC9F5ED42C8A._tcp"
    static let pcp: UInt8 = 0x23
    static let serviceId: [UInt8] = [0xFC, 0x9F, 0x5E]

    public static func randomEndpointId() -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return String((0..<4).map { _ in alphabet.randomElement()! })
    }

    /// `base64url(0x23, endpointId (4 ASCII bytes), 0xFC 0x9F 0x5E, 0x00 0x00)`.
    public static func serviceName(endpointId: String) -> String {
        var bytes: [UInt8] = [pcp]
        bytes.append(contentsOf: Array(endpointId.utf8.prefix(4)))
        bytes.append(contentsOf: serviceId)
        bytes.append(contentsOf: [0, 0])
        return base64URL(Data(bytes))
    }

    /// The `n` TXT record value before base64: a bit field (version 0, visible, device type), 16 random bytes, then the device
    /// name prefixed with its length.
    public static func endpointInfo(name: String, deviceType: QSDeviceType = .laptop, randomBytes: Data? = nil) -> Data {
        var out = Data([UInt8(deviceType.rawValue << 1)])
        let rnd = randomBytes.map { Data($0.prefix(16)) } ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        out.append(rnd)
        if rnd.count < 16 { out.append(Data(repeating: 0, count: 16 - rnd.count)) }
        var nameBytes = Array(name.utf8)
        if nameBytes.count > 255 {
            // Cut on a character boundary.
            var cut = 255
            while cut > 0, (nameBytes[cut] & 0xC0) == 0x80 { cut -= 1 }
            nameBytes = Array(nameBytes[0..<cut])
        }
        out.append(UInt8(nameBytes.count))
        out.append(contentsOf: nameBytes)
        return out
    }

    public struct Info: Equatable {
        public var name: String?
        public var deviceType: QSDeviceType
        public var visible: Bool
        public var qrData: Data?
    }

    /// Reads endpoint info (the `n` TXT record, or `ConnectionRequest.endpoint_info`).
    public static func parseEndpointInfo(_ d: Data) -> Info? {
        let b = [UInt8](d)
        guard b.count >= 17 else { return nil }
        let visible = (b[0] & 0x10) == 0
        let type = QSDeviceType(rawValue: Int((b[0] >> 1) & 0x07)) ?? .unknown
        var offset = 17
        var name: String?
        if visible {
            guard b.count > offset else { return nil }
            let len = Int(b[offset]); offset += 1
            guard b.count >= offset + len, let s = String(bytes: b[offset..<(offset + len)], encoding: .utf8) else { return nil }
            name = s
            offset += len
        }
        var qr: Data?
        while b.count - offset >= 2 {                // optional TLV records
            let t = b[offset], len = Int(b[offset + 1])
            offset += 2
            guard b.count - offset >= len else { break }
            if t == 1 { qr = Data(b[offset..<(offset + len)]) }
            offset += len
        }
        return Info(name: name, deviceType: type, visible: visible, qrData: qr)
    }

    public static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }

    public static func fromBase64URL(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}
