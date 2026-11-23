import AppKit
import SwiftUI

/// The menu-bar popover (MenuBarExtra, .window style) grows when its content grows but never shrinks:
/// after content goes away (e.g. notifications cleared) SwiftUI centres the smaller content inside the old,
/// taller window, leaving an empty outline above and below. This measures the content and resizes the
/// window to fit, keeping the top edge pinned under the menu bar icon.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private final class WindowProbe: NSView {
    var onWindow: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let w = window { onWindow?(w) }
    }
}

private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { let v = WindowProbe(); v.onWindow = onWindow; return v }
    func updateNSView(_ nsView: NSView, context: Context) {
        if let w = nsView.window { onWindow(w) }
    }
}

private final class WindowRef { weak var window: NSWindow? }

struct FitMenuBarWindow: ViewModifier {
    @State private var ref = WindowRef()
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in Color.clear.preference(key: ContentHeightKey.self, value: g.size.height) })
            .background(WindowReader { w in
                if ref.window !== w { ref.window = w; fit() }
            })
            .onPreferenceChange(ContentHeightKey.self) { h in
                height = h
                fit()
            }
    }

    private func fit() {
        guard let w = ref.window, height > 0 else { return }
        let target = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: w.contentLayoutRect.width, height: height)).height
        guard abs(w.frame.height - target) > 0.5 else { return }
        var f = w.frame
        f.origin.y = f.maxY - target   // keep the top edge where it is
        f.size.height = target
        w.setFrame(f, display: true, animate: false)
    }
}

extension View {
    /// Keep the menu-bar popover window exactly as tall as its content.
    func fitMenuBarWindow() -> some View { modifier(FitMenuBarWindow()) }
}
