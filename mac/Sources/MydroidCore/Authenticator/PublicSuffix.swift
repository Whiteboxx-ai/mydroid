import Foundation

/// eTLD+1 extraction with an embedded Public Suffix List (see `PublicSuffixData`).
/// `login.salesforce.com` -> `salesforce.com`, `accounts.google.co.in` -> `google.co.in`.
public struct PublicSuffixList: Sendable {
    public static let shared = PublicSuffixList(rules: PublicSuffixData.icannRules + "\n" + PublicSuffixData.privateRules)

    private var exact = Set<String>()
    private var wildcard = Set<String>()      // `*.ck` is stored as `ck`
    private var exceptions = Set<String>()    // `!www.ck` is stored as `www.ck`

    public init(rules: String) {
        for raw in rules.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if line.isEmpty || line.hasPrefix("//") { continue }
            if line.hasPrefix("!") { exceptions.insert(String(line.dropFirst())) }
            else if line.hasPrefix("*.") { wildcard.insert(String(line.dropFirst(2))) }
            else { exact.insert(line) }
        }
    }

    /// Lower-cases and trims a host: no scheme, port, path, credentials, brackets or trailing dot. IDN labels are kept as written
    /// (Unicode or `xn--`). Nil when nothing host-like is left.
    public static func normalizeHost(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<i]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if s.hasPrefix("[") { return nil }                       // IPv6 literal
        if let c = s.lastIndex(of: ":") { s = String(s[..<c]) }  // port
        while s.hasSuffix(".") { s.removeLast() }
        guard !s.isEmpty, s.count <= 253, !s.contains(" "), !s.hasPrefix(".") else { return nil }
        if s.contains("..") { return nil }
        return s
    }

    public static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    /// The public suffix of a host (`co.uk`, `com`), or nil for an IP address.
    public func publicSuffix(of host: String) -> String? {
        guard let h = Self.normalizeHost(host), !Self.isIPAddress(h) else { return nil }
        let labels = h.split(separator: ".").map(String.init)
        let n = suffixLength(labels)
        return labels.suffix(n).joined(separator: ".")
    }

    /// The registrable domain (eTLD+1). Nil for an IP address, a single label such as `localhost`, or a host that is itself a public suffix.
    public func registrableDomain(of host: String) -> String? {
        guard let h = Self.normalizeHost(host), !Self.isIPAddress(h) else { return nil }
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        let n = suffixLength(labels)
        guard labels.count > n else { return nil }
        return labels.suffix(n + 1).joined(separator: ".")
    }

    /// How many trailing labels form the public suffix, following the PSL algorithm (exceptions win, then the longest match, default one label).
    private func suffixLength(_ labels: [String]) -> Int {
        let count = labels.count
        for i in 0..<count {                                   // i = 0 is the whole host: longest candidate first
            let candidate = labels[i...].joined(separator: ".")
            if exceptions.contains(candidate) { return count - i - 1 }
            if exact.contains(candidate) { return count - i }
            if i + 1 < count, wildcard.contains(labels[(i + 1)...].joined(separator: ".")) { return count - i }
        }
        return 1
    }

    /// Whether `host` is `domain` or a subdomain of it.
    public static func host(_ host: String, isWithin domain: String) -> Bool {
        guard let h = normalizeHost(host), let d = normalizeHost(domain) else { return false }
        return h == d || h.hasSuffix("." + d)
    }
}
