import Foundation
import Darwin

public struct PairingSession: Sendable {
    public static let lifetime: TimeInterval = 600
    public let secret: Data
    public let ltk: Data
    public let createdAt: Date
    public var expires: Date { createdAt.addingTimeInterval(Self.lifetime) }
    public var isExpired: Bool { Date() >= expires }

    public init(secret: Data = MydroidCrypto.randomBytes(32), createdAt: Date = Date()) {
        self.secret = secret
        self.ltk = MydroidCrypto.ltk(fromPairingSecret: secret)
        self.createdAt = createdAt
    }

    /// `mydroid://pair?v=1&mac=<macId>&n=<name>&s=<b64url S>&a=<ip:port>,<ip:port>`
    public func url(macId: String, macName: String, addresses: [String]) -> String {
        PairingURL.build(macId: macId, macName: macName, secret: secret, addresses: addresses)
    }
}

public enum PairingURL {
    private static let allowed: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()

    public static func build(macId: String, macName: String, secret: Data, addresses: [String]) -> String {
        let n = macName.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "mydroid://pair?v=1&mac=\(macId)&n=\(n)&s=\(secret.base64url)&a=\(addresses.joined(separator: ","))"
    }
}

public enum NetworkInfo {
    /// IPv4 addresses of active, non-loopback interfaces, formatted `ip:port`.
    public static func addresses(port: UInt16) -> [String] {
        var result: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard ["utun", "awdl", "llw", "bridge", "ap", "gif", "stf", "anpi"].allSatisfy({ !name.hasPrefix($0) }) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }
            let entry = "\(ip):\(port)"
            if !result.contains(entry) { result.append(entry) }
        }
        return result
    }
}
