import SwiftUI
import AppKit
import MydroidCore

/// Centered empty, loading, permission or disconnected state.
struct StateView<Actions: View>: View {
    var icon: String
    var title: String
    var message: String
    var tint: Color = .secondary
    var busy = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.12)).frame(width: 64, height: 64)
                if busy { ProgressView().controlSize(.regular) }
                else { Image(systemName: icon).font(.system(size: 26, weight: .regular)).foregroundStyle(tint).symbolRenderingMode(.hierarchical) }
            }
            Text(title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
            Text(message).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 340)
            actions().padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension StateView where Actions == EmptyView {
    init(icon: String, title: String, message: String, tint: Color = .secondary, busy: Bool = false) {
        self.init(icon: icon, title: title, message: message, tint: tint, busy: busy) { EmptyView() }
    }
}

/// A slim strip at the top of a pane: something is off but cached content is still useful.
struct NoticeBar<Trailing: View>: View {
    var icon: String
    var text: String
    var tint: Color = .orange
    var busy = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) }
            else { Image(systemName: icon).foregroundStyle(tint).symbolRenderingMode(.hierarchical) }
            Text(text).font(.system(size: 12.5, weight: .medium)).lineLimit(2)
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }
}

extension NoticeBar where Trailing == EmptyView {
    init(icon: String, text: String, tint: Color = .orange, busy: Bool = false) {
        self.init(icon: icon, text: text, tint: tint, busy: busy) { EmptyView() }
    }
}

/// "Ask on your phone": sends `fix.open` and says where to look afterwards.
struct AskOnPhoneButton: View {
    @Environment(AppModel.self) private var model
    var kind: FixKind
    var title = "Ask on Phone"
    @State private var asked = false

    var body: some View {
        Button {
            model.fix(kind)
            withAnimation(.spring(duration: 0.3)) { asked = true }
            Task { try? await Task.sleep(for: .seconds(8)); withAnimation { asked = false } }
        } label: {
            Label(asked ? "Check your phone" : title, systemImage: asked ? "hand.point.up.left.fill" : "iphone.gen3.radiowaves.left.and.right")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .disabled(asked || model.state.link != .connected)
    }
}

/// Shown instead of a pane's content when there is no phone link.
struct DisconnectedState: View {
    @Environment(AppModel.self) private var model
    var what: String
    var body: some View {
        let phone = model.state.phone?.name ?? "Your phone"
        StateView(icon: "iphone.gen3.slash", title: "\(phone) isn\u{2019}t connected",
                  message: "\(what) return when it reconnects.",
                  tint: .orange, busy: false) {
            if let seen = model.state.lastSeen {
                Text("Last seen \(Fmt.lastSeen(seen))").font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
            }
            if model.state.link == .searching {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Looking\u{2026}").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

struct DisconnectedBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.state.link != .connected {
            NoticeBar(icon: "iphone.gen3.slash", text: "\(model.state.phone?.name ?? "Your phone") isn\u{2019}t connected",
                      busy: model.state.link == .searching)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(focused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 2))
        .animation(.easeOut(duration: 0.15), value: focused)
        .background(Button("") { focused = true }.keyboardShortcut("f", modifiers: .command).opacity(0).allowsHitTesting(false))
    }
}

/// Round avatar for a conversation: photo, initials, or a group glyph; with the app's badge for app chats.
struct ChatAvatar: View {
    var chat: ChatSummary
    var size: CGFloat = 40

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if chat.isGroup && chat.avatar == nil {
                ZStack {
                    let h = nameHue(chat.title)
                    LinearGradient(colors: [Color(hue: h, saturation: 0.45, brightness: 0.86), Color(hue: h, saturation: 0.65, brightness: 0.7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "person.2.fill").font(.system(size: size * 0.38)).foregroundStyle(.white)
                }
                .frame(width: size, height: size).clipShape(Circle())
                .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            } else {
                Avatar(name: chat.title, initials: Self.initials(chat.title), icon: chat.avatar, size: size)
            }
            if let app = chat.appName {
                AppIcon(data: chat.appIcon, name: app, size: size * 0.42)
                    .overlay(RoundedRectangle(cornerRadius: size * 0.1, style: .continuous).strokeBorder(.background, lineWidth: 1.5))
                    .offset(x: size * 0.06, y: size * 0.06)
            }
        }
        .frame(width: size, height: size)
    }

    static func initials(_ name: String) -> String {
        if name.filter(\.isNumber).count >= 6 && name.filter(\.isLetter).isEmpty { return "#" }
        let s = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2).compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return s.isEmpty ? "?" : s
    }
}

extension View {
    /// A bar of controls with the window's translucent material, like Messages and Photos.
    func barBackground() -> some View {
        background(.bar).overlay(alignment: .bottom) { Divider() }
    }
}

enum DayLabel {
    static func text(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day, days < 7 {
            return d.formatted(.dateTime.weekday(.wide))
        }
        if cal.component(.year, from: d) == cal.component(.year, from: now) { return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
        return d.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// "3:42 PM" today, otherwise "Yesterday", "Mon", "Nov 12" for the conversation list.
    static func listTime(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day, days < 7 {
            return d.formatted(.dateTime.weekday(.abbreviated))
        }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

enum ByteSize {
    static func text(_ n: Int64) -> String { n > 0 ? ByteCountFormatter.string(fromByteCount: n, countStyle: .file) : "" }
}
