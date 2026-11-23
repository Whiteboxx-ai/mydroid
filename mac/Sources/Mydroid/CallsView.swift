import SwiftUI
import AppKit
import MydroidCore

struct CallsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            RecentsList().frame(maxWidth: .infinity)
            Divider()
            DialPad().frame(width: 312)
        }
        .task(id: model.state.link) { model.calls.activate() }
    }
}

struct RecentsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var c = model.calls
        let rows = c.visible
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Show", selection: $c.filter) {
                    ForEach(CallsModel.Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                Spacer()
                if c.loading { ProgressView().controlSize(.small) }
                Button { c.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
                    .disabled(model.state.link != .connected || c.loading)
            }
            .padding(.horizontal, 14).padding(.vertical, 8).barBackground()
            if !rows.isEmpty { DisconnectedBar() }
            content(rows)
        }
        .background(.background)
    }

    @ViewBuilder private func content(_ rows: [CallRecord]) -> some View {
        let c = model.calls
        let s = model.state
        if s.link == .connected && s.settings.calls && (s.features.calls == .needsPermission || c.permissionDenied) {
            StateView(icon: "lock.shield", title: "Allow call access on your phone",
                      message: "One tap on your phone, then recents appear here.",
                      tint: .orange) { AskOnPhoneButton(kind: .calls) }
        } else if !s.settings.calls {
            StateView(icon: "phone", title: "Calls on your Mac",
                      message: "See recents, answer and decline from here.", tint: .accentColor) {
                Button("Turn On Calls") { model.updateSettings { $0.calls = true } }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        } else if rows.isEmpty {
            if s.link != .connected && !c.loaded { DisconnectedState(what: "Your recent calls") }
            else if c.loading || (!c.loaded && c.error == nil) {
                StateView(icon: "phone", title: "Loading recent calls", message: "From your phone\u{2026}", busy: true)
            } else if let err = c.error {
                StateView(icon: "exclamationmark.triangle", title: "Couldn't load calls", message: err, tint: .orange) {
                    Button("Try Again") { c.refresh() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            } else {
                StateView(icon: c.filter == .missed ? "phone.arrow.down.left" : "phone", title: c.filter == .missed ? "No missed calls" : "No recent calls",
                          message: c.filter == .missed ? "Calls you miss show up here." : "Calls on your phone show up here.")
            }
        } else {
            List(selection: Binding(get: { c.selection }, set: { c.selection = $0 })) {
                ForEach(rows) { r in
                    CallRow(record: r).tag(r.id)
                        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                        .listRowSeparator(.visible)
                }
            }
            .listStyle(.inset)
        }
    }
}

struct CallRow: View {
    @Environment(AppModel.self) private var model
    var record: CallRecord
    @State private var hover = false

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(tint.opacity(0.14)).frame(width: 34, height: 34)
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(tint).symbolRenderingMode(.hierarchical)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(record.isMissed ? Color.red : Color.primary).lineLimit(1)
                HStack(spacing: 4) {
                    Text(kindLabel)
                    if record.duration > 0 { Text("\u{00B7}"); Text(CallRow.duration(record.duration)).monospacedDigit() }
                    if !record.name.isEmpty, !record.number.isEmpty { Text("\u{00B7}"); Text(record.number).lineLimit(1) }
                }
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(DayLabel.listTime(record.date)).font(.system(size: 12)).foregroundStyle(.secondary)
            Button { model.calls.dial(record.number, name: record.name) } label: {
                Image(systemName: "phone.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(hover ? Color.white : Color.green)
                    .frame(width: 28, height: 28).background(hover ? Color.green : Color.green.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(record.number.isEmpty || model.state.link != .connected)
            .help("Call back on your phone")
            .accessibilityLabel("Call \(record.title)")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .onTapGesture(count: 2) { model.calls.dial(record.number, name: record.name) }
        .contextMenu {
            Button("Call on Phone") { model.calls.dial(record.number, name: record.name) }.disabled(record.number.isEmpty)
            Button("Message") {
                model.messages.newRecipients = record.number
                model.messages.startNewMessage()
                model.section = .messages
            }.disabled(record.number.isEmpty)
            Divider()
            Button("Copy Number") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.number, forType: .string) }
                .disabled(record.number.isEmpty)
        }
    }

    private var symbol: String {
        switch record.kind {
        case .incoming: return "phone.arrow.down.left"
        case .outgoing: return "phone.arrow.up.right"
        case .missed: return "phone.arrow.down.left"
        case .rejected: return "phone.down"
        }
    }
    private var tint: Color { record.isMissed ? .red : (record.kind == .incoming ? .green : .blue) }
    private var kindLabel: String {
        switch record.kind {
        case .incoming: return "Incoming"
        case .outgoing: return "Outgoing"
        case .missed: return "Missed"
        case .rejected: return "Declined"
        }
    }

    static func duration(_ s: Int) -> String {
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: Dial pad

struct DialPad: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    private static let keys: [[(String, String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")], [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")], [("*", ""), ("0", "+"), ("#", "")],
    ]

    var body: some View {
        @Bindable var c = model.calls
        let connected = model.state.link == .connected
        let match = c.records.first { MessagesModel.digits($0.number) == MessagesModel.digits(c.number) && !c.number.isEmpty && !$0.name.isEmpty }
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    TextField("Enter a number", text: $c.number)
                        .textFieldStyle(.plain)
                        .font(.system(size: c.number.count <= 11 ? 28 : (c.number.count <= 15 ? 23 : 18), weight: .light, design: .rounded))
                        .multilineTextAlignment(.center)
                        .focused($focused).onSubmit { c.dial(c.number) }
                    Button { c.backspace() } label: { Image(systemName: "delete.left").font(.system(size: 15)).foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Delete").opacity(c.number.isEmpty ? 0 : 1).disabled(c.number.isEmpty)
                }
                Text(match?.name ?? " ").font(.system(size: 12.5)).foregroundStyle(.secondary).frame(height: 16)
            }
            .padding(.horizontal, 24)

            VStack(spacing: 10) {
                ForEach(Array(Self.keys.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 14) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, k in
                            Button { c.press(k.0 == "0" ? "0" : k.0) } label: { KeyCap(digit: k.0, letters: k.1) }
                                .buttonStyle(KeyButtonStyle())
                        }
                    }
                }
            }

            Button { c.dial(c.number) } label: {
                Image(systemName: "phone.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 66, height: 46).background(Color.green.opacity(c.number.isEmpty || !connected ? 0.4 : 1), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(c.number.isEmpty || !connected)
            .help("Call on your phone")

            Group {
                if let note = c.note {
                    Label(note, systemImage: "iphone.gen3.radiowaves.left.and.right").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.green)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Text(connected ? "Calls ring on your phone. You talk on the phone." : "Connect your phone to place a call.")
                        .font(.system(size: 11.5)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
            }
            .frame(minHeight: 32)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.035)).background(Color(nsColor: .windowBackgroundColor))
        .animation(.spring(duration: 0.35), value: c.note)
        .onAppear { focused = false }
    }
}

struct KeyCap: View {
    var digit: String
    var letters: String
    var body: some View {
        VStack(spacing: 0) {
            Text(digit).font(.system(size: digit == "*" ? 28 : 24, weight: .regular, design: .rounded)).frame(height: 28)
            Text(letters.isEmpty ? " " : letters).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).kerning(1.2).frame(height: 10)
        }
        .frame(width: 64, height: 64)
    }
}

struct KeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(.primary.opacity(configuration.isPressed ? 0.18 : 0.08)))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: configuration.isPressed)
    }
}
