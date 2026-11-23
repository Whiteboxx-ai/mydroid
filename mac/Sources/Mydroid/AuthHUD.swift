import SwiftUI
import AppKit
import MydroidCore

// The small panel the ⌃⌥C shortcut shows near the menu bar. It never takes focus from the browser.

/// What a state says and how it looks.
struct AuthHUDPresentation: Equatable {
    enum Tone { case brand, good, warn, bad }
    var symbol: String
    var tone: Tone
    var title: String
    var detail: String?
    var spinner = false

    init(symbol: String, tone: Tone, title: String, detail: String? = nil, spinner: Bool = false) {
        self.symbol = symbol; self.tone = tone; self.title = title; self.detail = detail; self.spinner = spinner
    }
}

extension AuthHUDState {
    /// One short title, and at most one short line under it.
    var presentation: AuthHUDPresentation {
        switch self {
        case let .explainAutomation(b):
            return .init(symbol: "safari", tone: .brand, title: "Read the page address?",
                         detail: "macOS will ask to let Mydroid control \(b). Only the address is read.")
        case let .needsAutomation(b):
            return .init(symbol: "lock.shield", tone: .warn, title: "Allow Mydroid to control \(b)",
                         detail: "Privacy & Security \u{203A} Automation")
        case .needsAccessibility:
            return .init(symbol: "keyboard", tone: .warn, title: "Allow Mydroid to type",
                         detail: "Privacy & Security \u{203A} Accessibility")
        case let .unsupportedApp(name):
            return .init(symbol: "globe", tone: .warn, title: "Open the page in a browser",
                         detail: name == nil ? "Safari, Chrome, Edge, Brave or Arc." : "Not \(name!). Use Safari, Chrome, Edge, Brave or Arc.")
        case .noPage:
            return .init(symbol: "globe", tone: .warn, title: "No sign-in page found")
        case .asking:
            return .init(symbol: "iphone.gen3", tone: .brand, title: "Checking\u{2026}", spinner: true)
        case let .waiting(d):
            return .init(symbol: "iphone.gen3.radiowaves.left.and.right", tone: .brand, title: "Approve on your phone\u{2026}",
                         detail: d, spinner: true)
        case let .filled(d):
            return .init(symbol: "checkmark.circle.fill", tone: .good, title: "Filled \u{2713}", detail: d)
        case .denied:
            return .init(symbol: "xmark.circle.fill", tone: .bad, title: "Denied")
        case .timedOut:
            return .init(symbol: "clock.badge.exclamationmark", tone: .warn, title: "Timed out", detail: "Try again.")
        case .locked:
            return .init(symbol: "lock.fill", tone: .warn, title: "Phone is locked", detail: "Unlock it, then try again.")
        case .offline:
            return .init(symbol: "iphone.gen3.slash", tone: .warn, title: "Phone not connected")
        case .pageChanged:
            return .init(symbol: "arrow.triangle.2.circlepath", tone: .warn, title: "The page changed", detail: "Try again.")
        case .failed:
            return .init(symbol: "exclamationmark.triangle.fill", tone: .warn, title: "Something went wrong")
        case let .noMatch(d):
            return .init(symbol: "link.badge.plus", tone: .warn, title: "No account for \(d)")
        case let .link(d, entries):
            return .init(symbol: "link", tone: .brand, title: "Which account is \(d)?",
                         detail: entries.isEmpty ? "No accounts on your phone yet." : nil)
        case let .linkConfirm(d, _, l):
            return .init(symbol: "exclamationmark.shield.fill", tone: .bad, title: "\(d) may not be the real site", detail: l.summary)
        case let .ambiguous(d, _):
            return .init(symbol: "person.2.fill", tone: .brand, title: "Which account for \(d)?")
        }
    }
}

private extension AuthHUDPresentation.Tone {
    var color: Color {
        switch self {
        case .brand: return .brand
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
        }
    }
}

/// A spinner that also renders in an off-screen image (a `ProgressView` doesn't).
struct HUDSpinner: View {
    var color: Color
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Circle().trim(from: 0.08, to: 0.75)
                .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees((t * 330).truncatingRemainder(dividingBy: 360)))
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// Drawn by hand, because system prominent buttons turn grey in a panel that isn't the key window (this one never is).
struct HUDButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color
    var weight: Font.Weight
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: weight))
            .foregroundStyle(foreground)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct AuthHUDView: View {
    var model: AuthHUDModel
    static let width: CGFloat = 340

    var body: some View {
        let s = model.state
        let p = s.presentation
        let a = model.actions
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: p.detail == nil ? .center : .top, spacing: 10) {
                ZStack {
                    Circle().fill(p.tone.color.opacity(0.16))
                    Image(systemName: p.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.tone.color)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(p.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        if p.spinner { HUDSpinner(color: p.tone.color) }
                    }
                    if let d = p.detail {
                        Text(d).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            content(s, a)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: Self.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(p.title)
    }

    @ViewBuilder
    private func content(_ s: AuthHUDState, _ a: AuthHUDActions) -> some View {
        switch s {
        case .explainAutomation:
            buttons { secondary("Cancel", a.cancel); primary("Continue", a.proceed) }
        case .needsAutomation:
            buttons { secondary("Close", a.cancel); primary("Open Settings", a.openAutomation) }
        case .needsAccessibility:
            buttons { secondary("Close", a.cancel); primary("Open Settings", a.openAccessibility) }
        case .waiting, .asking:
            buttons { secondary("Cancel", a.cancel) }
        case .noMatch:
            buttons { secondary("Cancel", a.cancel); primary("Link\u{2026}", a.startLink) }
        case let .link(_, entries):
            accountList(entries.map { ($0.id, $0.issuer, $0.account) }, a)
        case let .ambiguous(_, choices):
            accountList(choices.map { ($0.id, $0.issuer, $0.account) }, a)
        case .linkConfirm:
            buttons { secondary("Cancel", a.cancel); primary("Link anyway", a.confirmLookalike, destructive: true) }
        default:
            EmptyView()
        }
    }

    private func accountList(_ rows: [(id: String, issuer: String, account: String)], _ a: AuthHUDActions) -> some View {
        VStack(spacing: 6) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(rows, id: \.id) { r in
                        Button { a.pick(r.id) } label: {
                            HStack(spacing: 8) {
                                Text(r.issuer.isEmpty ? "Account" : r.issuer).font(.system(size: 12.5, weight: .medium))
                                Text(r.account).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(r.issuer), \(r.account)")
                    }
                }
            }
            .frame(maxHeight: 190).fixedSize(horizontal: false, vertical: rows.count <= 5)
            buttons { secondary("Cancel", a.cancel) }
        }
    }

    private func buttons<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 8) { Spacer(minLength: 0); c() }
    }

    private func primary(_ t: String, _ action: @escaping () -> Void, destructive: Bool = false) -> some View {
        Button(action: action) { Text(t) }.buttonStyle(HUDButtonStyle(fill: destructive ? .red : Color.brand, foreground: .white, weight: .semibold))
    }

    private func secondary(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(t) }.buttonStyle(HUDButtonStyle(fill: Color.primary.opacity(0.10), foreground: .primary, weight: .medium))
    }
}

/// Shows the HUD in a floating, non-activating panel under the menu bar.
@MainActor
final class AuthHUDPanelController: AuthHUDPresenting {
    private var panel: FloatingPanel?
    private var host: NSHostingView<AuthHUDView>?
    private var hideWork: DispatchWorkItem?

    func present(_ model: AuthHUDModel) {
        hideWork?.cancel()
        if panel == nil {
            let p = FloatingPanel(size: NSSize(width: AuthHUDView.width + 16, height: 100))
            p.becomesKeyOnlyIfNeeded = true
            let h = NSHostingView(rootView: AuthHUDView(model: model))
            p.contentView = h
            host = h; panel = p
        }
        guard let p = panel, let h = host else { return }
        h.rootView = AuthHUDView(model: model)
        h.layoutSubtreeIfNeeded()
        let size = NSSize(width: AuthHUDView.width + 16, height: max(60, h.fittingSize.height))
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let target = NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 8, width: size.width, height: size.height)
        let appearing = !p.isVisible
        if appearing {
            p.setFrame(target.offsetBy(dx: 0, dy: 16), display: false)
            p.alphaValue = 0
            p.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = appearing ? 0.28 : 0.15
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            p.animator().setFrame(target, display: true)
            p.animator().alphaValue = 1
        }
        NSAccessibility.post(element: p, notification: .announcementRequested,
                             userInfo: [.announcement: model.state.presentation.title, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func dismiss() {
        guard let p = panel else { return }
        panel = nil; host = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }
}

/// For fixtures and tests.
@MainActor
final class NullHUD: AuthHUDPresenting {
    private(set) var states: [AuthHUDState] = []
    private(set) var dismissals = 0
    func present(_ model: AuthHUDModel) { states.append(model.state) }
    func dismiss() { dismissals += 1 }
}
