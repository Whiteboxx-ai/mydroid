import Foundation

// PROTOCOL.md 15: media handoff. Pure rules, no AppKit, so the URL mapping, the position and the AppleScript text can be tested.
// Nothing here logs a track URI or id.

/// A track or episode the phone says it is playing (`media.state.mediaId`, filtered like PROTOCOL.md 13.1).
public enum MediaRef: Equatable, Sendable {
    public enum Kind: String, Sendable { case track, episode }
    /// `spotify:track:<22 base62>` or `spotify:episode:<22 base62>`.
    case spotify(Kind, id: String)
    /// Any other http(s) page.
    case web(URL)

    /// Spotify ids are exactly 22 base62 characters.
    public static let spotifyIDLength = 22

    public static func isSpotifyID(_ s: String) -> Bool {
        s.utf8.count == spotifyIDLength && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }
    }

    /// nil for anything that isn't `spotify:track:<id>`, `spotify:episode:<id>` or an http(s) URL. A link to open.spotify.com
    /// (with or without a locale prefix or a `?si=` tail) becomes the same `.spotify` value as its URI.
    public init?(mediaId raw: String?) {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.utf8.count <= 2048, !s.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("spotify:") {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, parts[0].lowercased() == "spotify", let kind = Kind(rawValue: parts[1].lowercased()),
                  Self.isSpotifyID(parts[2]) else { return nil }
            self = .spotify(kind, id: parts[2])
            return
        }
        guard let url = URL(string: s), LinkPolicy.isWeb(url) else { return nil }
        if let host = url.host?.lowercased(), host == "open.spotify.com" {
            // /track/<id>, /episode/<id>, or /intl-xx/track/<id>
            var comps = url.path.split(separator: "/").map(String.init)
            if let first = comps.first, first.hasPrefix("intl-") { comps.removeFirst() }
            if comps.count >= 2, let kind = Kind(rawValue: comps[0].lowercased()), Self.isSpotifyID(comps[1]) {
                self = .spotify(kind, id: comps[1])
                return
            }
        }
        self = .web(url)
    }

    /// The page to open when Spotify for Mac isn't there (or fails).
    public var webURL: URL {
        switch self {
        case .spotify(let kind, let id): return URL(string: "https://open.spotify.com/\(kind.rawValue)/\(id)")!
        case .web(let u): return u
        }
    }

    /// `spotify:track:<id>` for a Spotify item, nil for other links.
    public var spotifyURI: String? {
        if case .spotify(let kind, let id) = self { return "spotify:\(kind.rawValue):\(id)" }
        return nil
    }

    /// The value to keep on `MediaState` (the canonical form), or nil when the phone's value isn't acceptable.
    public static func filtered(_ raw: String?) -> String? {
        guard let ref = MediaRef(mediaId: raw) else { return nil }
        return ref.spotifyURI ?? ref.webURL.absoluteString
    }
}

public enum ContinueOnMac {
    public static let spotifyBundleID = "com.spotify.client"

    /// Where playback should start, in seconds, from the phone's last sample: `position` at `ts`, plus the time since if it is
    /// still playing, never past the end. Never negative. Rounded to a tenth of a second.
    public static func startSeconds(of m: MediaState, at now: Date) -> Double {
        let ms = max(0, m.position(at: now))
        return (Double(ms) / 100).rounded() / 10
    }

    /// Escapes text for an AppleScript string literal. Backslash and double quote are the only characters that can end or alter one;
    /// line breaks and other control characters are dropped.
    public static func appleScriptEscape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            default:
                if u.value < 0x20 || u.value == 0x7f { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// Plain decimal text with one digit, whatever the Mac's region, for example `83.4`.
    static func decimal(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }

    /// The script that makes Spotify for Mac play the item from `seconds`. nil unless `uri` is exactly `spotify:track:<22 base62>`
    /// or `spotify:episode:<22 base62>`, so nothing else can ever reach AppleScript.
    /// Spotify needs a moment to load before it accepts a position, so the script waits until it is playing.
    public static func spotifyScript(uri: String, seconds: Double) -> String? {
        guard let ref = MediaRef(mediaId: uri), let clean = ref.spotifyURI, clean == uri else { return nil }
        let literal = appleScriptEscape(clean)
        var lines = [
            "tell application id \"\(spotifyBundleID)\"",
            "play track \"\(literal)\"",
        ]
        if seconds >= 1 {
            lines += [
                "repeat 25 times",
                "if player state is playing then exit repeat",
                "delay 0.2",
                "end repeat",
                "set player position to \(decimal(seconds))",
            ]
        }
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    /// A web search for what is playing: Google, "<title> <artist>". nil when there is nothing to search for.
    public static func searchURL(title: String, artist: String) -> URL? {
        let q = Text.collapse([title, artist].filter { !$0.isEmpty }.joined(separator: " "))
        guard !q.isEmpty else { return nil }
        return URL(string: "https://www.google.com/search?q=" + Text.encode(Text.shorten(q, to: 200)))
    }

    /// What the button on the Now Playing row offers.
    public enum Offer: Equatable, Sendable {
        case continueOnMac(MediaRef)
        case searchWeb(URL)
    }

    public static func offer(for m: MediaState) -> Offer? {
        if let ref = MediaRef(mediaId: m.mediaId) { return .continueOnMac(ref) }
        if let u = searchURL(title: m.title, artist: m.artist) { return .searchWeb(u) }
        return nil
    }
}
