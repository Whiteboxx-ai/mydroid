import Foundation

// PROTOCOL.md section 10, "Presenting": is something on this Mac in slideshow mode right now? Pure rules over what the app layer observed.

public struct FrontWindow: Equatable, Sendable {
    public var title: String
    public var fullScreen: Bool
    public init(title: String, fullScreen: Bool) { self.title = title; self.fullScreen = fullScreen }
}

public enum PresentingDetector {
    public static let keynote = "com.apple.iWork.Keynote"
    public static let powerPoint = "com.microsoft.Powerpoint"
    public static let preview = "com.apple.Preview"

    /// Browsers that can present Google Slides or PowerPoint Online full-screen.
    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// Apps worth watching with the light poll while they are in front. Anything else is only checked when the active app or space changes.
    public static func isCandidate(bundleID: String?) -> Bool {
        guard let b = bundleID else { return false }
        return b == keynote || b == powerPoint || b == preview || browsers.contains(b)
    }

    static func mentionsSlideshow(_ title: String) -> Bool {
        let t = title.lowercased()
        return t.contains("slide show") || t.contains("slideshow")
    }

    static func mentionsOnlineDeck(_ title: String) -> Bool {
        let t = title.lowercased()
        return t.contains("google slides") || t.contains("powerpoint")
    }

    /// The name of the app that is presenting, or nil.
    /// - `keynotePlaying`: Keynote's own answer (AppleScript `playing`), when Automation allows asking; nil when unknown.
    /// - `windows`: the frontmost app's windows (title when readable, and whether each fills a screen).
    public static func presenting(bundleID: String?, appName: String, windows: [FrontWindow], keynotePlaying: Bool?) -> String? {
        guard let bundle = bundleID else { return nil }
        let full = windows.filter(\.fullScreen)
        switch bundle {
        case keynote:
            if let playing = keynotePlaying { return playing ? "Keynote" : nil }
            return full.isEmpty ? nil : "Keynote"
        case powerPoint:
            // A slide show window is titled "... Slide Show ..." and fills the screen.
            if windows.contains(where: { mentionsSlideshow($0.title) }) { return "PowerPoint" }
            return nil
        default:
            if full.contains(where: { mentionsSlideshow($0.title) }) { return appName }
            if browsers.contains(bundle), full.contains(where: { mentionsOnlineDeck($0.title) }) { return appName }
            return nil
        }
    }
}
