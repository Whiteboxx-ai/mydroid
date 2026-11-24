import SwiftUI
import AppKit
import MydroidCore

/// Non-activating floating panel that can still take keyboard focus for text fields.
final class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private func screenFrame() -> NSRect { (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900) }

// MARK: Fallback notification banners

enum BannerKind: Equatable {
    case notification
    /// A link from the phone, waiting for the user to open it.
    case link(URL, from: String)
    case lowBattery(title: String, detail: String)
    /// Quick Share: a device wants to send something and waits for Accept or Decline.
    case quickShareRequest(QuickShareIncoming)
    /// Text that arrived by Quick Share and is now on the clipboard.
    case copied(from: String, preview: String)
    /// Files saved from a Quick Share transfer.
    case saved(QuickShareDone)
}

@MainActor @Observable
final class BannerItem {
    var notification: PhoneNotification
    var kind: BannerKind = .notification
    var paused = false
    var autoCopied = false
    init(_ n: PhoneNotification, autoCopied: Bool = false, kind: BannerKind = .notification) {
        notification = n; self.autoCopied = autoCopied; self.kind = kind
    }
}

@MainActor
final class BannerCenter {
    weak var model: AppModel?
    private struct Entry { let item: BannerItem; let panel: FloatingPanel; var timer: Timer? }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    static let width: CGFloat = 372
    private let gap: CGFloat = 4

    func show(_ n: PhoneNotification, autoCopied: Bool = false) { show(BannerItem(n, autoCopied: autoCopied)) }

    func showLink(_ url: URL, from phone: String) {
        let n = PhoneNotification(key: "link:" + UUID().uuidString, pkg: "mydroid.link", app: "Link", title: phone, text: url.absoluteString)
        show(BannerItem(n, kind: .link(url, from: phone)))
    }

    func showLowBattery(title: String, detail: String) {
        let n = PhoneNotification(key: "mydroid.battery", pkg: "mydroid.battery", app: "Battery", title: title, text: detail)
        show(BannerItem(n, kind: .lowBattery(title: title, detail: detail)))
    }

    static func quickShareKey(_ id: String) -> String { "qs:" + id }

    func showQuickShareRequest(_ r: QuickShareIncoming) {
        let n = PhoneNotification(key: Self.quickShareKey(r.id), pkg: "mydroid.quickshare", app: "Quick Share", title: r.sender, text: r.summary)
        show(BannerItem(n, kind: .quickShareRequest(r)))
    }

    func showCopied(from: String, preview: String) {
        let n = PhoneNotification(key: "copied:" + UUID().uuidString, pkg: "mydroid.quickshare", app: "Quick Share", title: from, text: preview)
        show(BannerItem(n, kind: .copied(from: from, preview: preview)))
    }

    func showSaved(_ d: QuickShareDone) {
        let n = PhoneNotification(key: "saved:" + d.id, pkg: "mydroid.quickshare", app: "Quick Share", title: d.sender, text: d.files.first?.name ?? "")
        show(BannerItem(n, kind: .saved(d)))
    }

    private func show(_ item: BannerItem) {
        let n = item.notification
        let autoCopied = item.autoCopied
        if let e = entries[n.key] {
            e.item.notification = n; e.item.autoCopied = autoCopied; e.item.kind = item.kind
            e.panel.setContentSize(NSSize(width: Self.width, height: BannerView.height(for: e.item)))
            restack(); schedule(n.key); return
        }
        guard let model else { return }
        let height = BannerView.height(for: item)
        let panel = FloatingPanel(size: NSSize(width: Self.width, height: height))
        let view = BannerView(item: item, onClose: { [weak self] in self?.close(key: n.key) },
                              onDismiss: { [weak self] in self?.close(key: n.key); model.dismiss(item.notification) })
            .environment(model).environment(model.ui)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        panel.contentView = host
        entries[n.key] = Entry(item: item, panel: panel, timer: nil)
        order.insert(n.key, at: 0)
        // Start off to the right and fade in.
        let target = frame(at: order.firstIndex(of: n.key)!, height: height)
        panel.setFrame(target.offsetBy(dx: 40, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        restack()
        schedule(n.key)
        while order.count > 4, let last = order.last { close(key: last) }
    }

    private func schedule(_ key: String) {
        entries[key]?.timer?.invalidate()
        var secs: TimeInterval = (entries[key]?.item.notification.otp != nil && entries[key]?.item.autoCopied == false) ? 14 : 7
        if let k = entries[key]?.item.kind, k != .notification {
            switch k {
            case .quickShareRequest: secs = 31        // the connection gives up after 30 s and closes the banner itself
            case .copied: secs = 6
            default: secs = 14
            }
        }
        let t = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let e = self.entries[key] else { return }
                if e.item.paused || e.panel.isKeyWindow { self.schedule(key) } else { self.close(key: key) }
            }
        }
        entries[key]?.timer = t
    }

    func close(key: String) {
        guard let e = entries.removeValue(forKey: key) else { return }
        e.timer?.invalidate()
        order.removeAll { $0 == key }
        let panel = e.panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().setFrame(panel.frame.offsetBy(dx: 40, dy: 0), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
        restack()
    }

    func closeAll() { for k in order { close(key: k) } }

    private func frame(at index: Int, height: CGFloat) -> NSRect {
        let s = screenFrame()
        var y = s.maxY - 10
        for k in order.prefix(index) { y -= (entries[k]?.panel.frame.height ?? 100) + gap }
        return NSRect(x: s.maxX - Self.width - 12, y: y - height, width: Self.width, height: height)
    }

    private func restack() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            for (i, k) in order.enumerated() {
                guard let p = entries[k]?.panel else { continue }
                p.animator().setFrame(frame(at: i, height: p.frame.height), display: true)
            }
        }
    }
}

struct BannerView: View {
    @Bindable var item: BannerItem
    var onClose: () -> Void
    var onDismiss: () -> Void
    @Environment(NotifUIState.self) private var ui
    @State private var hover = false

    private var n: PhoneNotification { item.notification }

    /// Panel height for a notification, so the stack can lay panels out before they render.
    static func height(for item: BannerItem) -> CGFloat {
        switch item.kind {
        case .notification: return height(for: item.notification, autoCopied: item.autoCopied)
        case .link: return 92
        case .lowBattery: return 72
        case .quickShareRequest: return 124
        case .copied: return 66
        case .saved: return 78
        }
    }

    static func height(for n: PhoneNotification, autoCopied: Bool) -> CGFloat {
        if n.otp != nil { return autoCopied ? 66 : 92 }
        if n.isMessage { return n.canReply ? 108 : 80 }
        return n.canReply ? 124 : 90
    }

    var body: some View {
        Group {
            if case let .link(url, from) = item.kind { linkBody(url, from: from) }
            else if case let .lowBattery(title, detail) = item.kind { batteryBody(title, detail) }
            else if case let .quickShareRequest(r) = item.kind { quickShareBody(r) }
            else if case let .copied(from, preview) = item.kind { copiedFromBody(from, preview) }
            else if case let .saved(d) = item.kind { savedBody(d) }
            else if n.otp != nil && item.autoCopied { copiedBody }
            else if n.otp != nil { otpBody }
            else if n.isMessage { messageBody }
            else { appBody }
        }
        .modifier(BannerMenu(n: n, enabled: item.kind == .notification))
        .padding(12)
        .frame(width: BannerCenter.width, height: Self.height(for: item), alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .overlay(alignment: .topLeading) {
            if hover {
                HStack(spacing: 6) {
                    Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .help("Hide")
                    if item.kind == .notification {
                        Button(action: onDismiss) { Image(systemName: "trash").font(.system(size: 8, weight: .bold)) }
                            .help("Dismiss on phone")
                        if !n.pkg.isEmpty {
                            Button { ui.mute(n); onClose() } label: { Image(systemName: "bell.slash").font(.system(size: 8, weight: .bold)) }
                                .help("Mute \(n.displayApp)")
                        }
                    }
                }
                .buttonStyle(CircleChromeButton())
                .offset(x: -6, y: -6)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.25), value: hover)
        .onHover { hover = $0; item.paused = $0 }
        .onChange(of: ui.replyStatus[n.key]) { _, s in if s == .sent { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { onClose() } } }
        .padding(6)
    }

    private func linkBody(_ url: URL, from: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.brand, .brand.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                Image(systemName: "link").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }.frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Link from \(from)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).lineLimit(1)
                Text(url.absoluteString).font(.system(size: 12.5, weight: .medium)).lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button { NSWorkspace.shared.open(url); onClose() } label: {
                Text("Open").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent).controlSize(.regular)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Quick Share

    private func quickShareBody(_ r: QuickShareIncoming) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 11) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [.brand, .brand.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                    Image(systemName: r.deviceType.isPhone ? "iphone.gen3" : "laptopcomputer").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                }.frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick Share").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Text("\(r.sender) wants to share").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(r.summary).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("PIN \(r.pin)").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("Should match on \(r.sender)").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { ui.quickShareRespond(r.id, false); onClose() } label: { Text("Decline").font(.system(size: 12, weight: .medium)) }
                    .buttonStyle(.bordered).controlSize(.regular)
                Button { ui.quickShareRespond(r.id, true); onClose() } label: { Text("Accept").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.borderedProminent).controlSize(.regular).keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func copiedFromBody(_ from: String, _ preview: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard.fill").font(.system(size: 21)).foregroundStyle(Color.brand).symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 1) {
                Text("Copied from \(from)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(preview).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer()
        }
        .frame(maxHeight: .infinity)
    }

    private func savedBody(_ d: QuickShareDone) -> some View {
        let folder = d.files.first?.url.deletingLastPathComponent().lastPathComponent ?? "Downloads"
        let title = d.files.count == 1 ? "Saved to \(folder)" : "Saved \(d.files.count) files to \(folder)"
        let detail = d.files.count == 1 ? "\(d.files[0].name) \u{00B7} from \(d.sender)" : "From \(d.sender)"
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button { NSWorkspace.shared.activateFileViewerSelecting(d.files.map(\.url)); onClose() } label: {
                Text("Show in Finder").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered).controlSize(.regular)
        }
        .frame(maxHeight: .infinity)
    }

    private func batteryBody(_ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "battery.25percent").font(.system(size: 24)).foregroundStyle(.red).symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .frame(maxHeight: .infinity)
    }

    // OTP: leads with the code.
    private var otpBody: some View {
        let copied = ui.copiedKey == n.key
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Verification code", systemImage: "lock.shield.fill").labelStyle(.titleAndIcon)
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Brand.accent).textCase(.uppercase)
                CodeText(code: n.otp?.grouped ?? "", size: 28)
                Text(codeSourceLine(n)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { ui.copyCode(n) } label: {
                Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent).controlSize(.regular).tint(copied ? .green : Brand.accent)
        }
    }

    // OTP that was already copied for you: small and quiet.
    private var copiedBody: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Code copied").font(.system(size: 13, weight: .semibold))
                Text("\(n.otp?.grouped ?? "") \u{00B7} \(codeSourceLine(n))").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .frame(maxHeight: .infinity)
    }

    private var messageBody: some View {
        let c = n.effectiveConversation ?? Conversation(title: n.title)
        let title = c.title.isEmpty ? n.displayApp : c.title
        let last = c.last
        let line: String = {
            guard let last else { return n.text }
            if last.isMine { return "You: \(last.text)" }
            return c.isGroup && !last.sender.isEmpty ? "\(last.sender): \(last.text)" : last.text
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Avatar(name: title, initials: n.initials(for: title), icon: c.avatar, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if c.isGroup { Image(systemName: "person.2.fill").font(.system(size: 9.5)).foregroundStyle(.secondary) }
                        Spacer(minLength: 4)
                        Text("via \(n.displayApp)").font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Text(line).font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.88)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .opensNotification(n, then: onClose)
            if n.canReply { ReplyField(n: n, placeholder: "Reply to \(title)") }
        }
    }

    private var appBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                AppIcon(data: n.icon, name: n.displayApp, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(n.displayApp).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("now").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                    if !n.title.isEmpty { Text(n.title).font(.system(size: 13, weight: .semibold)).lineLimit(1) }
                    Text(n.text).font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.85)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .opensNotification(n, then: onClose)
            if n.canReply { ReplyField(n: n, placeholder: "Reply") }
        }
    }
}

/// The right-click menu on a banner. Only phone notifications get one (not links, battery or Quick Share banners).
private struct BannerMenu: ViewModifier {
    var n: PhoneNotification
    var enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.notificationMenu(n) } else { content }
    }
}

struct CircleChromeButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 18, height: 18)
            .background(.thickMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: Call panel

@MainActor
final class CallPanelController {
    weak var model: AppModel?
    private var panel: FloatingPanel?
    private var hideTask: Task<Void, Never>?

    func sync(call: CallInfo?) {
        hideTask?.cancel()
        guard let call, let model else { hide(); return }
        if model.hiddenCalls.contains(call.callId) {
            hide()
            if call.phase == .ended { model.hub.clearCall(); model.hiddenCalls.remove(call.callId) }
            return
        }
        if panel == nil {
            let size = NSSize(width: CallView.width, height: 160)       // fitted to the content just after it appears
            let p = FloatingPanel(size: size)
            let host = NSHostingView(rootView: CallView().environment(model))
            host.frame = NSRect(origin: .zero, size: size)
            p.contentView = host
            let s = screenFrame()
            let target = NSRect(x: s.midX - size.width / 2, y: s.maxY - size.height - 12, width: size.width, height: size.height)
            p.setFrame(target.offsetBy(dx: 0, dy: 30), display: false)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
                p.animator().setFrame(target, display: true)
                p.animator().alphaValue = 1
            }
            panel = p
        }
        scheduleFit()
        if call.phase == .ended {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { return }
                self?.model?.hub.clearCall()
                self?.hide()
            }
        }
    }

    /// SwiftUI updates a moment after the call state changes, and animates; measure when it has settled, and again after.
    private func scheduleFit() {
        DispatchQueue.main.async { [weak self] in self?.fit() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.fit() }
    }

    /// Makes the panel as tall as the call view wants, keeping its top edge where it is.
    private func fit() {
        guard let p = panel, let host = p.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let h = ceil(host.fittingSize.height)
        guard h > 60, abs(p.frame.height - h) > 0.5 else { return }
        let top = p.frame.maxY
        p.setFrame(NSRect(x: p.frame.minX, y: top - h, width: p.frame.width, height: h), display: true, animate: false)
    }

    private func hide() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
            p.animator().setFrame(p.frame.offsetBy(dx: 0, dy: 20), display: true)
        }, completionHandler: { p.orderOut(nil) })
    }
}
