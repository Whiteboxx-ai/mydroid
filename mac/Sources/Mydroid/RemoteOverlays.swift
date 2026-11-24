import SwiftUI
import AppKit
import ApplicationServices
import MydroidCore

// MARK: Laser pointer

/// A transparent, click-through window over the main display that draws a soft glow where the phone points.
/// It is always above full-screen slideshows and follows you across Spaces. Nothing here takes input or focus.
@MainActor
final class LaserOverlay {
    var mailbox: LaserMailbox?
    var color: NSColor = LaserColor.red.nsColor { didSet { applyColor() } }

    private var window: NSPanel?
    private let glow = CAGradientLayer()
    private let core = CALayer()
    private var timer: Timer?
    private var smoother = LaserSmoother(tau: 0.05)
    private var lastFrame = ProcessInfo.processInfo.systemUptime
    private var lastVersion = -1
    private var previewing = false
    /// The phone wants the laser on.
    private var requested = false
    private var visible = false
    private var hideWork: DispatchWorkItem?
    private static let glowSize: CGFloat = 96
    private static let coreSize: CGFloat = 14

    func setOn(_ value: Bool) {
        requested = value
        refresh()
    }

    private func refresh() {
        let want = requested || previewing
        if want, !visible { visible = true; appear() }
        else if !want, visible { visible = false; disappear() }
    }

    private func makeWindow() -> NSPanel {
        let screen = NSScreen.screens.first ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true                  // clicks and the pointer go straight through
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.hidesOnDeactivate = false
        w.animationBehavior = .none
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
        v.wantsLayer = true
        v.layer?.backgroundColor = .clear
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.bounds = CGRect(x: 0, y: 0, width: Self.glowSize, height: Self.glowSize)
        core.bounds = CGRect(x: 0, y: 0, width: Self.coreSize, height: Self.coreSize)
        core.cornerRadius = Self.coreSize / 2
        v.layer?.addSublayer(glow)
        v.layer?.addSublayer(core)
        w.contentView = v
        window = w
        applyColor()
        return w
    }

    private func applyColor() {
        let c = color.usingColorSpace(.sRGB) ?? color
        glow.colors = [c.withAlphaComponent(0.85).cgColor, c.withAlphaComponent(0.35).cgColor, c.withAlphaComponent(0).cgColor]
        glow.locations = [0, 0.35, 1]
        core.backgroundColor = c.cgColor
        core.shadowColor = c.cgColor
        core.shadowOpacity = 1
        core.shadowRadius = 8
        core.shadowOffset = .zero
    }

    private func appear() {
        hideWork?.cancel()
        let w = window ?? makeWindow()
        if let s = NSScreen.screens.first { w.setFrame(s.frame, display: false) }     // the display may have changed
        let (p, version) = mailbox?.get() ?? (CGPoint(x: 0.5, y: 0.5), 0)
        smoother.jump(to: p)
        lastVersion = version
        place(p)
        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; w.animator().alphaValue = 1 }
        lastFrame = ProcessInfo.processInfo.systemUptime
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.frame() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func disappear() {
        guard let w = window else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; w.animator().alphaValue = 0 }, completionHandler: nil)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.visible else { return }
                self.timer?.invalidate(); self.timer = nil
                self.window?.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func frame() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.1, now - lastFrame)
        lastFrame = now
        if previewing, !requested {
            let t = now * 3
            smoother.target = CGPoint(x: 0.5 + 0.25 * sin(t), y: 0.5 + 0.18 * sin(t * 2))
        } else if let box = mailbox {
            let (p, v) = box.get()
            if v != lastVersion { lastVersion = v; smoother.target = p }
        }
        place(smoother.step(dt: dt))
    }

    /// `p` is 0...1 over the display, y down.
    private func place(_ p: CGPoint) {
        guard let v = window?.contentView else { return }
        let pt = CGPoint(x: p.x * v.bounds.width, y: (1 - p.y) * v.bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.position = pt
        core.position = pt
        CATransaction.commit()
    }

    /// For tests: the overlay window, built but never shown.
    var builtWindow: NSPanel { window ?? makeWindow() }

    /// For tests and previews: draws the glow at `p` (0...1, y down) into an image of `size` points, without ordering any window front.
    func snapshot(at p: CGPoint, size: CGSize, backdrop: NSColor) -> NSBitmapImageRep? {
        let w = builtWindow
        w.setFrame(NSRect(origin: .zero, size: size), display: false)
        w.contentView?.frame = NSRect(origin: .zero, size: size)
        place(p)
        guard let v = w.contentView else { return nil }
        v.layer?.backgroundColor = backdrop.cgColor
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        v.layer?.backgroundColor = .clear
        return rep
    }

    /// Two seconds of figure-of-eight, for Settings. Overlay only; posts no input.
    func preview() {
        guard !requested, !previewing else { return }
        previewing = true
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.previewing = false; self?.refresh() }
        }
    }
}

// MARK: Presenting detection

/// Watches the front app for a slideshow (PROTOCOL.md 10). Cheap by design: it looks when the active app or Space changes, and polls every 2 s
/// only while a likely presenting app is in front.
@MainActor
final class PresentingMonitor {
    enum AutomationState: Equatable {
        case notInstalled
        /// Keynote is installed but nobody asked Mydroid to look at it yet.
        case notAsked
        case allowed
        case denied
    }

    var onChange: (String?) -> Void = { _ in }
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var last: String?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            })
        }
        // A slideshow starting inside the front app doesn't change the active app; the screens notification covers entering full screen.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        })
        evaluate()
    }

    private func setPolling(_ on: Bool) {
        if on, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.evaluate() } }
        } else if !on {
            timer?.invalidate(); timer = nil
        }
    }

    func evaluate() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // Mydroid's own popover or Settings in front says nothing about a slideshow: keep what we knew.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        let bundle = app.bundleIdentifier
        setPolling(PresentingDetector.isCandidate(bundleID: bundle))
        let windows = Self.windows(of: app)
        let keynote: Bool? = bundle == PresentingDetector.keynote ? keynotePlaying() : nil
        let result = PresentingDetector.presenting(bundleID: bundle, appName: app.localizedName ?? "", windows: windows, keynotePlaying: keynote)
        if result != last { last = result; onChange(result) }
    }

    // MARK: Windows

    private static func displayFrames() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &n) == .success else { return [] }
        return ids.prefix(Int(n)).map { CGDisplayBounds($0) }
    }

    private static func covers(_ r: CGRect, _ screens: [CGRect]) -> Bool {
        screens.contains { abs($0.minX - r.minX) < 2 && abs($0.minY - r.minY) < 2 && abs($0.width - r.width) < 2 && abs($0.height - r.height) < 2 }
    }

    /// Titles and full-screen state through Accessibility when it is allowed. Titles of other apps' windows aren't available any other way
    /// (they need Screen Recording), so without Accessibility only "covers a whole screen" is known.
    static func windows(of app: NSRunningApplication) -> [FrontWindow] {
        let screens = displayFrames()
        if AXIsProcessTrusted() {
            let el = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(el, 0.25)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &value) == .success, let list = value as? [AXUIElement] {
                return list.prefix(8).map { w in
                    func attr(_ k: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(w, k as CFString, &v) == .success ? v : nil }
                    let title = attr(kAXTitleAttribute) as? String ?? ""
                    var full = (attr("AXFullScreen") as? Bool) ?? false
                    if !full, let p = attr(kAXPositionAttribute), let s = attr(kAXSizeAttribute) {
                        var pt = CGPoint.zero, sz = CGSize.zero
                        if AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) {
                            full = covers(CGRect(origin: pt, size: sz), screens)
                        }
                    }
                    return FrontWindow(title: title, fullScreen: full)
                }
            }
        }
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { d in
            guard (d[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  let b = d[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return nil }
            return FrontWindow(title: (d[kCGWindowName as String] as? String) ?? "", fullScreen: covers(CGRect(x: x, y: y, width: w, height: h), screens))
        }
    }

    // MARK: Keynote

    var automationState: AutomationState {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: PresentingDetector.keynote) != nil else { return .notInstalled }
        switch status(ask: false) {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notAsked      // consent not asked yet, or Keynote isn't running (then the answer can't be known)
        }
    }

    /// `AEDeterminePermissionToAutomateTarget`. With `ask` the system may show its Automation prompt (Keynote has to be running).
    private func status(ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: PresentingDetector.keynote)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
    }

    func requestKeynoteAutomation() { _ = status(ask: true) }

    /// Asks Keynote itself, but only if macOS already lets Mydroid (never triggers a prompt on its own).
    private func keynotePlaying() -> Bool? {
        guard status(ask: false) == noErr else { return nil }
        var err: NSDictionary?
        let r = NSAppleScript(source: "tell application \"Keynote\" to return playing")?.executeAndReturnError(&err)
        guard err == nil, let r else { return nil }
        return r.booleanValue
    }
}

// MARK: Accessibility card panel

/// The floating card: "Allow Mydroid to control this Mac from your phone".
@MainActor
final class AccessibilityPromptController {
    weak var controller: RemoteController?
    private var panel: FloatingPanel?

    func show() {
        guard let controller, panel == nil else { return }
        let size = NSSize(width: AccessibilityCardView.width + 12, height: 220)
        let p = FloatingPanel(size: size)
        let host = NSHostingView(rootView: AccessibilityCardView(
            open: { [weak controller] in controller?.openAccessibilitySettings() },
            notNow: { [weak controller] in controller?.dismissCard() },
            reset: { [weak controller] in controller?.resetAccessibilityAndAsk() },
            resized: { [weak self] in self?.fit() }
        ))
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        let s = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let target = NSRect(x: s.midX - size.width / 2, y: s.maxY - size.height - 12, width: size.width, height: size.height)
        p.setFrame(target.offsetBy(dx: 0, dy: 24), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            p.animator().setFrame(target, display: true)
            p.animator().alphaValue = 1
        }
        panel = p
        DispatchQueue.main.async { [weak self] in self?.fit() }
    }

    private func fit() {
        guard let p = panel, let host = p.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let h = ceil(host.fittingSize.height)
        guard h > 60, abs(p.frame.height - h) > 0.5 else { return }
        let top = p.frame.maxY
        p.setFrame(NSRect(x: p.frame.minX, y: top - h, width: p.frame.width, height: h), display: true, animate: false)
    }

    func hide() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            p.animator().alphaValue = 0
            p.animator().setFrame(p.frame.offsetBy(dx: 0, dy: 16), display: true)
        }, completionHandler: { p.orderOut(nil) })
    }
}
