import Foundation

// Phishing protection (PROTOCOL.md 14.3): before the user links an unknown site to an account, warn when its domain
// looks like one of their issuers' domains. Pure and offline.

/// A site the user already has an account for: the issuer's display name and the domains the phone knows for it.
public struct KnownSite: Equatable, Sendable {
    public var issuer: String
    public var domains: [String]
    public init(issuer: String, domains: [String]) { self.issuer = issuer; self.domains = domains }

    public static func from(_ entries: [AuthEntry]) -> [KnownSite] {
        entries.map { KnownSite(issuer: $0.issuer, domains: $0.domains) }
    }
}

public struct Lookalike: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Same name once look-alike characters are folded (`paypa1.com`, `rnicrosoft.com`, Cyrillic letters).
        case confusable
        /// One or two letters off (`salesfroce.com`).
        case typo
        /// The known name with something added (`salesforce-login.com`).
        case containsName
        /// The known name used as a subdomain of something else (`salesforce.com.evil.io`).
        case nameInSubdomain
        /// The same name under another ending (`salesforce.co`).
        case otherSuffix
    }
    public var kind: Kind
    /// The known domain it resembles, or the issuer's name when the phone has no domain for it.
    public var resembles: String
    public var issuer: String

    public var summary: String {
        switch kind {
        case .confusable: return "Looks like \(resembles), with different characters"
        case .typo: return "Looks like \(resembles), with a letter changed"
        case .containsName: return "Contains \(resembles), but is a different site"
        case .nameInSubdomain: return "Uses \(resembles), but is a different site"
        case .otherSuffix: return "Same name as \(resembles), different ending"
        }
    }
}

public enum LookalikeDetector {
    /// Nil when the domain is, or sits under, one of the known domains, or resembles none of them.
    public static func assess(host: String, known: [KnownSite], psl: PublicSuffixList = .shared) -> Lookalike? {
        guard let h = PublicSuffixList.normalizeHost(host), !PublicSuffixList.isIPAddress(h) else { return nil }
        let candidate = psl.registrableDomain(of: h) ?? h
        // A genuine domain of one of the entries is never a lookalike.
        for site in known { for d in site.domains where PublicSuffixList.host(h, isWithin: d) { return nil } }

        let (cLabel, cSuffix) = split(candidate, psl)
        let cSkeleton = skeleton(cLabel)
        let hostLabels = h.split(separator: ".").map(String.init)

        for site in known {
            // Names to compare against: each known domain's own name, then the issuer's name.
            var targets: [(label: String, shown: String, suffix: String?, full: String?)] = []
            for d in site.domains {
                guard let nd = PublicSuffixList.normalizeHost(d) else { continue }
                let reg = psl.registrableDomain(of: nd) ?? nd
                let (l, s) = split(reg, psl)
                targets.append((l, reg, s, reg))
            }
            let issuerName = site.issuer.lowercased().filter { $0.isLetter || $0.isNumber }
            if issuerName.count >= 5 { targets.append((issuerName, site.issuer, nil, nil)) }

            for t in targets {
                let kSkeleton = skeleton(t.label)
                guard kSkeleton.count >= 4 else { continue }
                func hit(_ kind: Lookalike.Kind) -> Lookalike { Lookalike(kind: kind, resembles: t.shown, issuer: site.issuer) }

                // salesforce.com.evil.io: the known domain spelled out in front of the real one.
                if let full = t.full, hostLabels.count > 2, h.contains(full + ".") {
                    if !PublicSuffixList.host(h, isWithin: full) { return hit(.nameInSubdomain) }
                }
                if cSkeleton == kSkeleton {
                    if cLabel == t.label, let ks = t.suffix, cSuffix != ks { return hit(.otherSuffix) }
                    if cLabel != t.label || t.suffix == cSuffix { return hit(.confusable) }
                }
                let sub = hostLabels.dropLast(candidate.split(separator: ".").count).map(skeleton)
                if kSkeleton.count >= 5, sub.contains(kSkeleton) { return hit(.nameInSubdomain) }
                let limit = kSkeleton.count >= 9 ? 2 : (kSkeleton.count >= 5 ? 1 : 0)
                if limit > 0, cSkeleton != kSkeleton, abs(cSkeleton.count - kSkeleton.count) <= limit,
                   editDistance(cSkeleton, kSkeleton) <= limit { return hit(.typo) }
                if kSkeleton.count >= 5, cSkeleton != kSkeleton, cSkeleton.contains(kSkeleton) { return hit(.containsName) }
            }
        }
        return nil
    }

    /// The name part and the public suffix of a registrable domain: `salesforce.co.uk` -> (`salesforce`, `co.uk`).
    private static func split(_ registrable: String, _ psl: PublicSuffixList) -> (String, String?) {
        let labels = registrable.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return (registrable, nil) }
        return (labels[0], labels.dropFirst().joined(separator: "."))
    }

    // MARK: Skeletons

    /// Characters that read like another one, folded to it.
    private static let confusables: [Character: Character] = [
        "0": "o", "1": "l", "3": "e", "5": "s", "\u{0131}": "i", "\u{0456}": "i", "\u{0430}": "a", "\u{0435}": "e", "\u{043E}": "o", "\u{0440}": "p",
        "\u{0441}": "c", "\u{0443}": "y", "\u{0445}": "x", "\u{0455}": "s", "\u{0501}": "d", "\u{0261}": "g", "\u{03BF}": "o", "\u{03B1}": "a",
        "\u{03BD}": "v", "\u{04CF}": "l", "\u{0406}": "i", "\u{0410}": "a", "\u{0415}": "e", "\u{041E}": "o", "\u{0420}": "p", "\u{0421}": "c",
        "\u{0425}": "x", "\u{043A}": "k", "\u{0442}": "t", "\u{043D}": "h", "\u{0432}": "b", "\u{043C}": "m", "|": "l",
    ]

    /// A comparison form: decoded from punycode, lower-case, accents removed, look-alikes folded, `rn`/`vv` merged, no hyphens.
    static func skeleton(_ label: String) -> String {
        var s = Punycode.decodeLabel(label.lowercased())
        s = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var out = ""
        for ch in s where ch != "-" && ch != "_" { out.append(confusables[ch] ?? ch) }
        return out.replacingOccurrences(of: "rn", with: "m").replacingOccurrences(of: "vv", with: "w")
    }

    /// Damerau-Levenshtein (adjacent swaps count as one edit).
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var d = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { d[i][0] = i }
        for j in 0...y.count { d[0][j] = j }
        for i in 1...x.count {
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[x.count][y.count]
    }
}

/// Punycode (RFC 3492) decoding for `xn--` labels, so an internationalised look-alike is compared by what it shows.
enum Punycode {
    static func decodeLabel(_ label: String) -> String {
        guard label.hasPrefix("xn--") else { return label }
        return decode(String(label.dropFirst(4))) ?? label
    }

    static func decode(_ input: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        var n = 128, i = 0, bias = 72
        var output: [UInt32] = []
        var rest = Substring(input)
        if let d = input.lastIndex(of: "-") {
            output = input[..<d].unicodeScalars.map { $0.value }
            rest = input[input.index(after: d)...]
        }
        let digits = Array(rest.unicodeScalars)
        var pos = 0
        func digit(_ u: Unicode.Scalar) -> Int? {
            switch u.value {
            case 48...57: return Int(u.value) - 22          // 0-9 -> 26-35
            case 65...90: return Int(u.value) - 65
            case 97...122: return Int(u.value) - 97
            default: return nil
            }
        }
        func adapt(_ delta: Int, _ points: Int, _ first: Bool) -> Int {
            var d = first ? delta / damp : delta / 2
            d += d / points
            var k = 0
            while d > ((base - tMin) * tMax) / 2 { d /= base - tMin; k += base }
            return k + (base - tMin + 1) * d / (d + skew)
        }
        while pos < digits.count {
            let oldI = i
            var w = 1, k = base
            while true {
                guard pos < digits.count, let dg = digit(digits[pos]) else { return nil }
                pos += 1
                i += dg * w
                let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if dg < t { break }
                w *= base - t
                k += base
                if w > Int(Int32.max) { return nil }
            }
            let len = output.count + 1
            bias = adapt(i - oldI, len, oldI == 0)
            n += i / len
            i %= len
            guard let _ = Unicode.Scalar(UInt32(n)) else { return nil }
            output.insert(UInt32(n), at: i)
            i += 1
        }
        var s = ""
        for v in output { guard let u = Unicode.Scalar(v) else { return nil }; s.unicodeScalars.append(u) }
        return s
    }
}
