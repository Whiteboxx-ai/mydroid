import SwiftUI
import AppKit

/// Mydroid's teal. The same hue as the Android app's primary, lightened in dark mode so it keeps its contrast.
enum Brand {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.25, green: 0.76, blue: 0.68, alpha: 1)      // 40C1AE
            : NSColor(srgbRed: 0.043, green: 0.431, blue: 0.388, alpha: 1)   // 0B6E63
    })
}
