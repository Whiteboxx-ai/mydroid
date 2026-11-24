import SwiftUI
import AppKit
import MydroidCore

/// What the notification views need from the app. The views never touch AppModel, so they can be
/// rendered off-screen with fixture data.
@MainActor @Observable
final class NotifUIState {
    var replyStatus: [String: ReplyStatus] = [:]
    /// Key of the notification whose code was just copied.
    var copiedKey: String?
    @ObservationIgnored var reply: (PhoneNotification, String) -> Void = { _, _ in }
    @ObservationIgnored var dismiss: (PhoneNotification) -> Void = { _ in }
    @ObservationIgnored var perform: (PhoneNotification, Int) -> Void = { _, _ in }
    @ObservationIgnored var copyCode: (PhoneNotification) -> Void = { _ in }
    @ObservationIgnored var mute: (PhoneNotification) -> Void = { _ in }
    /// A conversation was expanded or collapsed (read sync, PROTOCOL.md 7.6).
    @ObservationIgnored var opened: (PhoneNotification) -> Void = { _ in }
    @ObservationIgnored var closed: (PhoneNotification) -> Void = { _ in }
    /// Accept (true) or decline (false) a Quick Share request.
    @ObservationIgnored var quickShareRespond: (String, Bool) -> Void = { _, _ in }

    // Opening a notification (PROTOCOL.md 13).
    @ObservationIgnored var router = OpenRouter(locator: WorkspaceLocator())
    /// The "When clicked" choice for an app (Settings > Notifications).
    @ObservationIgnored var clickBehavior: (String) -> ClickBehavior = { _ in .default }
    /// A click on a row, banner or system notification.
    @ObservationIgnored var open: (PhoneNotification) -> Void = { _ in }
    @ObservationIgnored var openOnPhone: (PhoneNotification) -> Void = { _ in }
    @ObservationIgnored var openOnWeb: (PhoneNotification) -> Void = { _ in }
    @ObservationIgnored var search: (PhoneNotification) -> Void = { _ in }
    @ObservationIgnored var copyText: (PhoneNotification) -> Void = { _ in }

    /// What a plain click does under the user's choice for this app.
    func clickAction(_ n: PhoneNotification) -> OpenAction { router.action(for: n, preference: clickBehavior(n.pkg)) }

    /// The right-click menu, in groups (a divider goes between groups).
    func menu(for n: PhoneNotification) -> [[NotifMenuEntry]] {
        let plan = router.plan(for: n)
        var open: [NotifMenuEntry] = [NotifMenuEntry(kind: .openOnPhone, title: "Open on phone", symbol: "iphone.gen3")]
        if plan.web != nil { open.append(NotifMenuEntry(kind: .openOnWeb, title: "Open on web", symbol: "safari")) }
        if plan.search != nil { open.append(NotifMenuEntry(kind: .search, title: "Search the web", symbol: "magnifyingglass")) }
        var other = [NotifMenuEntry(kind: .copyText, title: "Copy text", symbol: "doc.on.doc")]
        if !n.pkg.isEmpty { other.append(NotifMenuEntry(kind: .mute, title: "Mute \(n.displayApp)", symbol: "bell.slash")) }
        return [open, other]
    }

    func run(_ kind: NotifMenuEntry.Kind, _ n: PhoneNotification) {
        switch kind {
        case .openOnPhone: openOnPhone(n)
        case .openOnWeb: openOnWeb(n)
        case .search: search(n)
        case .copyText: copyText(n)
        case .mute: mute(n)
        }
    }
}

/// The right-click menu for a notification row or banner.
struct NotificationMenu: View {
    @Environment(NotifUIState.self) private var ui
    var n: PhoneNotification
    var body: some View {
        let groups = ui.menu(for: n)
        ForEach(Array(groups.enumerated()), id: \.offset) { i, group in
            if i > 0 { Divider() }
            ForEach(group) { e in
                Button { ui.run(e.kind, n) } label: { Label(e.title, systemImage: e.symbol) }
            }
        }
    }
}

extension View {
    /// Right-click menu: Open on phone, Open on web, Search the web, Copy text, Mute.
    func notificationMenu(_ n: PhoneNotification) -> some View { contextMenu { NotificationMenu(n: n) } }

    /// A click on this part of a row opens the notification. Buttons and fields inside it keep their own clicks.
    func opensNotification(_ n: PhoneNotification, enabled: Bool = true, then: @escaping () -> Void = {}) -> some View {
        modifier(OpensNotification(n: n, enabled: enabled, then: then))
    }
}

private struct OpensNotification: ViewModifier {
    @Environment(NotifUIState.self) private var ui
    var n: PhoneNotification
    var enabled: Bool
    var then: () -> Void
    func body(content: Content) -> some View {
        if enabled {
            content
                .contentShape(Rectangle())
                .onTapGesture { ui.open(n); then() }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "Open") { ui.open(n); then() }
        } else {
            content
        }
    }
}

// MARK: Small pieces

func nameHue(_ name: String) -> Double {
    var h: UInt32 = 5381
    for u in name.unicodeScalars { h = h &* 33 &+ u.value }
    return Double(h % 360) / 360
}

/// The app's icon from the phone, or a colored tile with the app's first letter.
struct AppIcon: View {
    var data: Data?
    var name: String
    var size: CGFloat = 16
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        ZStack {
            if let data, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                let h = nameHue(name)
                LinearGradient(colors: [Color(hue: h, saturation: 0.5, brightness: 0.9), Color(hue: h, saturation: 0.7, brightness: 0.7)],
                               startPoint: .top, endPoint: .bottom)
                Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.55, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// Reply field with a send button, shared by conversations and app notifications.
struct ReplyField: View {
    @Environment(NotifUIState.self) private var ui
    var n: PhoneNotification
    var placeholder: String
    var autoFocus = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var status: ReplyStatus? { ui.replyStatus[n.key] }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain).focused($focused)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(.primary.opacity(0.07), in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
                    .onSubmit(send)
                    .disabled(status == .sending)
                Group {
                    switch status {
                    case .sending: ProgressView().controlSize(.small)
                    case .sent: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 20))
                    default:
                        Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(text.isEmpty ? Color.secondary.opacity(0.5) : Brand.accent)
                            .disabled(text.isEmpty)
                    }
                }
                .frame(width: 24)
            }
            if case let .failed(msg) = status { Text("Couldn't send. \(msg)").font(.caption2).foregroundStyle(.red).padding(.leading, 6) }
        }
        .onChange(of: status) { _, s in if s == .sent { text = "" } }
        .onAppear { if autoFocus { focused = true } }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { ui.reply(n, t) }
    }
}

struct ActionLinks: View {
    @Environment(NotifUIState.self) private var ui
    var n: PhoneNotification
    var showReply = false
    var onReply: () -> Void = {}
    var body: some View {
        HStack(spacing: 14) {
            if showReply { Button("Reply", action: onReply) }
            Button("Dismiss") { ui.dismiss(n) }
            ForEach(n.actions.prefix(2), id: \.index) { a in
                Button(a.title) { ui.perform(n, a.index) }
            }
            if !n.pkg.isEmpty {
                Button("Mute app") { ui.mute(n) }
                    .foregroundStyle(.secondary)
                    .help("Stop notifications from \(n.displayApp)")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Brand.accent)
    }
}

struct SectionHeader: View {
    var title: String
    var count: Int
    var trailing: (title: String, action: () -> Void)? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            if count > 0 {
                Text("\(count)").font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Brand.accent.opacity(0.18), in: Capsule()).foregroundStyle(Brand.accent)
            }
            Spacer()
            if let trailing {
                Button(trailing.title, action: trailing.action).buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }
}

extension View {
    func card(_ opacity: Double = 0.04, radius: CGFloat = 12) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.primary.opacity(opacity)))
    }
}

// MARK: Verification codes

struct CodeCardsSection: View {
    var list: NotificationList
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let codes = list.activeCodes(at: ctx.date)
            VStack(spacing: 8) {
                ForEach(codes.prefix(2)) { n in
                    CodeCard(n: n, now: ctx.date)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.4, bounce: 0.2), value: codes.map(\.key))
        }
    }
}

/// The code in a monospaced font, digit groups separated by a narrow gap.
struct CodeText: View {
    var code: String
    var size: CGFloat
    var body: some View {
        HStack(spacing: size * 0.3) {
            ForEach(Array(code.split(separator: " ").enumerated()), id: \.offset) { _, g in
                Text(String(g)).font(.system(size: size, weight: .semibold, design: .monospaced))
            }
        }
        .lineLimit(1).minimumScaleFactor(0.6).fixedSize()
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(code.filter { $0 != " " }.map(String.init).joined(separator: " "))
    }
}

/// "HDFC Bank · via Messages"
func codeSourceLine(_ n: PhoneNotification) -> String {
    let via = n.displayApp
    guard let src = n.otp?.source, !src.isEmpty, src != via else { return via }
    return via.isEmpty ? src : "\(src) \u{00B7} via \(via)"
}

struct CodeCard: View {
    @Environment(NotifUIState.self) private var ui
    var n: PhoneNotification
    var now: Date = Date()

    var body: some View {
        let code = n.otp?.grouped ?? ""
        let copied = ui.copiedKey == n.key
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.accent)
                Text("Verification code").font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.accent).textCase(.uppercase)
                Spacer()
                Text(Fmt.relative(n.when, now: now)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(alignment: .center) {
                CodeText(code: code, size: 32)
                Spacer(minLength: 8)
                Button { ui.copyCode(n) } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12.5, weight: .semibold)).frame(minWidth: 66)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderedProminent).controlSize(.regular)
                .tint(copied ? .green : Brand.accent)
                .animation(.spring(duration: 0.3), value: copied)
            }
            Text(codeSourceLine(n)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.accent.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.accent.opacity(0.25), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Verification code \(n.otp?.code.map(String.init).joined(separator: " ") ?? ""), \(codeSourceLine(n))")
    }
}

// MARK: Popover section: Messages + Notifications

struct NotificationsPanel: View {
    var list: NotificationList
    var enabled = true
    var scrollable = true
    var initiallyExpanded: Set<String> = []
    var initiallyOpenStacks: Set<String> = []
    @Environment(NotifUIState.self) private var ui
    @State private var contentHeight: CGFloat = 0
    @State private var expanded: Set<String> = []
    @State private var openStacks: Set<String> = []
    @State private var seeded = false

    var body: some View {
        let messages = list.messages
        let others = list.others
        VStack(alignment: .leading, spacing: 10) {
            if !enabled {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "From your phone", count: 0)
                    EmptyNote(icon: "bell.slash", title: "Notifications are off", subtitle: "Turn them on in Settings.")
                }
            } else if messages.isEmpty && others.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "From your phone", count: 0)
                    EmptyNote(icon: "checkmark.circle", title: "All caught up", subtitle: nil)
                }
            } else {
                scrolling {
                    VStack(alignment: .leading, spacing: 12) {
                        if !messages.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                SectionHeader(title: "Messages", count: messages.count)
                                VStack(spacing: 4) {
                                    ForEach(messages) { n in
                                        ConversationRow(n: n, expanded: binding($expanded, n.key))
                                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                                    removal: .move(edge: .trailing).combined(with: .opacity)))
                                    }
                                }
                            }
                        }
                        if !others.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                SectionHeader(title: "Notifications", count: others.count,
                                              trailing: others.count > 1 ? ("Clear all", { withAnimation(.spring(duration: 0.4)) { others.forEach(ui.dismiss) } }) : nil)
                                VStack(spacing: 10) {
                                    ForEach(AppGroup.make(others)) { g in
                                        AppGroupView(group: g, open: binding($openStacks, g.id))
                                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                                    removal: .move(edge: .trailing).combined(with: .opacity)))
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 1)
                }
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.2), value: list.items.map(\.key))
        .animation(.spring(duration: 0.4, bounce: 0.2), value: expanded)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: openStacks)
        .onAppear {
            guard !seeded else { return }
            seeded = true; expanded = initiallyExpanded; openStacks = initiallyOpenStacks
        }
    }

    @ViewBuilder private func scrolling<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if scrollable {
            ScrollView {
                content().background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 60), 380))
            .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
        } else {
            content()
        }
    }

    private func binding(_ set: Binding<Set<String>>, _ key: String) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(key) },
                set: { if $0 { set.wrappedValue.insert(key) } else { set.wrappedValue.remove(key) } })
    }
}

// MARK: Conversations

struct ConversationRow: View {
    @Environment(NotifUIState.self) private var ui
    var n: PhoneNotification
    @Binding var expanded: Bool
    @State private var hover = false

    var body: some View {
        let c = n.effectiveConversation ?? Conversation(title: n.title)
        let title = c.title.isEmpty ? n.displayApp : c.title
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Avatar(name: title, initials: n.initials(for: title), icon: c.avatar, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if c.isGroup {
                            Image(systemName: "person.2.fill").font(.system(size: 9.5)).foregroundStyle(.secondary)
                                .accessibilityLabel("Group")
                        }
                        Spacer(minLength: 4)
                        Text(Fmt.relative(c.last?.when ?? n.when)).font(.system(size: 11)).foregroundStyle(.tertiary)
                        // The chevron reads the conversation here; the rest of the row opens it in the app (or on the phone).
                        Button { expanded.toggle() } label: {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .frame(width: 22, height: 18).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(expanded ? "Hide messages" : "Show messages")
                    }
                    if !expanded, let last = c.last {
                        Text(previewLine(last, group: c.isGroup))
                            .font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.85)).lineLimit(2)
                            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("via \(n.displayApp)").font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // "Do nothing" for this app: the row falls back to expanding, so it never feels dead.
                if ui.clickAction(n) == .none { expanded.toggle() } else { ui.open(n) }
            }
            .accessibilityAddTraits(.isButton)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Bubbles(messages: c.messages, isGroup: c.isGroup)
                    if n.canReply { ReplyField(n: n, placeholder: "Reply to \(title)") }
                    ActionLinks(n: n).padding(.leading, 4)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(9)
        .card(hover || expanded ? 0.07 : 0.045)
        .notificationMenu(n)
        .onHover { hover = $0 }
        .onChange(of: expanded) { _, now in if now { ui.opened(n) } else { ui.closed(n) } }
        .onDisappear { if expanded { ui.closed(n) } }
    }

    private func previewLine(_ m: ConversationMessage, group: Bool) -> String {
        if m.isMine { return "You: \(m.text)" }
        return group && !m.sender.isEmpty ? "\(m.sender): \(m.text)" : m.text
    }
}

extension PhoneNotification {
    func initials(for name: String) -> String {
        let s = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2).compactMap { $0.first }
            .map { String($0).uppercased() }.joined()
        return s.isEmpty ? "?" : s
    }
}

struct Bubbles: View {
    @Environment(\.colorScheme) private var scheme
    var messages: [ConversationMessage]
    var isGroup: Bool

    var body: some View {
        VStack(spacing: 2) {
            let msgs = Array(messages.suffix(5))
            ForEach(Array(msgs.enumerated()), id: \.offset) { i, m in
                let startsRun = i == 0 || msgs[i - 1].sender != m.sender
                VStack(alignment: m.isMine ? .trailing : .leading, spacing: 2) {
                    if isGroup, !m.isMine, startsRun {
                        Text(m.sender).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(senderColor(m.sender))
                            .padding(.leading, 10).padding(.top, i == 0 ? 0 : 4)
                    }
                    HStack(spacing: 0) {
                        if m.isMine { Spacer(minLength: 56) }
                        Text(m.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(m.isMine ? Color.white : Color.primary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(m.isMine ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.primary.opacity(0.09)),
                                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .fixedSize(horizontal: false, vertical: true)
                        if !m.isMine { Spacer(minLength: 56) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: m.isMine ? .trailing : .leading)
                .padding(.top, startsRun && i > 0 && !isGroup ? 4 : 0)
            }
        }
    }

    private func senderColor(_ s: String) -> Color { Color(hue: nameHue(s), saturation: 0.6, brightness: scheme == .dark ? 0.9 : 0.58) }
}

// MARK: App notifications

struct AppGroup: Identifiable {
    var id: String
    var app: String
    var icon: Data?
    var items: [PhoneNotification]

    static func make(_ list: [PhoneNotification]) -> [AppGroup] {
        var groups: [AppGroup] = []
        for n in list {
            let id = n.pkg.isEmpty ? n.displayApp : n.pkg
            if let i = groups.firstIndex(where: { $0.id == id }) {
                groups[i].items.append(n)
                if groups[i].icon == nil { groups[i].icon = n.icon }
            } else {
                groups.append(AppGroup(id: id, app: n.displayApp, icon: n.icon, items: [n]))
            }
        }
        return groups
    }
}

struct AppGroupView: View {
    @Environment(NotifUIState.self) private var ui
    var group: AppGroup
    @Binding var open: Bool

    var body: some View {
        let stacked = group.items.count > 2 && !open
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                AppIcon(data: group.icon, name: group.app, size: 16)
                Text(group.app).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                if stacked {
                    Text("+\(group.items.count - 1) more").font(.system(size: 11)).foregroundStyle(.tertiary)
                } else if group.items.count > 1 {
                    Text("\(group.items.count)").font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundStyle(.tertiary)
                }
                Spacer()
                if group.items.count > 2 {
                    Button(open ? "Show less" : "Clear") {
                        if open { open = false } else { group.items.forEach(ui.dismiss) }
                    }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)

            if stacked {
                Button { open = true } label: {
                    VStack(spacing: 0) {
                        AppNotificationRow(n: group.items[0], interactive: false)
                        StackLayers()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 3) {
                    ForEach(group.items) { AppNotificationRow(n: $0) }
                }
            }
        }
    }
}

/// Two thin edges peeking out under the newest notification, like a Notification Center stack.
private struct StackLayers: View {
    private func edge(_ inset: CGFloat, _ opacity: Double) -> some View {
        UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(opacity)).frame(height: 5).padding(.horizontal, inset)
    }
    var body: some View {
        VStack(spacing: 1) { edge(8, 0.045); edge(16, 0.03) }.padding(.top, 1)
    }
}

struct AppNotificationRow: View {
    @Environment(NotifUIState.self) private var ui
    var n: PhoneNotification
    var interactive = true
    @State private var replying = false
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(n.title.isEmpty ? n.displayApp : n.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Fmt.relative(n.when)).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                if !n.text.isEmpty {
                    Text(n.text).font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.85)).lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .opensNotification(n, enabled: interactive)
            if interactive {
                if replying && n.canReply {
                    ReplyField(n: n, placeholder: "Reply", autoFocus: true).transition(.move(edge: .top).combined(with: .opacity))
                }
                ActionLinks(n: n, showReply: n.canReply && !replying) {
                    withAnimation(.spring(duration: 0.35, bounce: 0.25)) { replying = true }
                }
                .opacity(hover || replying ? 1 : 0.75)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(hover && interactive ? 0.07 : 0.05)
        .notificationMenu(n)
        .onHover { hover = $0 }
        .onChange(of: ui.replyStatus[n.key]) { _, s in
            if s == .sent { withAnimation(.spring(duration: 0.4)) { replying = false } }
        }
    }
}
