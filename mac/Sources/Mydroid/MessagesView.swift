import SwiftUI
import AppKit
import MydroidCore

struct MessagesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ConversationList()
                .frame(width: 322)
            Divider()
            ThreadPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: model.state.link) { model.messages.refreshThreads() }
    }
}

// MARK: Conversation list

struct ConversationList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model.messages
        let rows = m.summaries()
        let sms = m.availability
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SearchField(text: $m.query, prompt: "Search messages")
                Button { m.startNewMessage() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 14, weight: .medium)).frame(width: 26, height: 24)
                }
                .buttonStyle(.borderless)
                .help("New message (\u{2318}N)")
                .disabled(model.state.link != .connected)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)

            if !rows.isEmpty { DisconnectedBar() }
            if model.state.link == .connected { smsNotice(sms, hasRows: !rows.isEmpty) }

            if rows.isEmpty {
                emptyState(sms)
            } else {
                List(selection: Binding(get: { m.selection }, set: { m.open($0) })) {
                    ForEach(rows) { c in
                        ChatRow(chat: c)
                            .tag(c.id)
                            .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 8))
                            .listRowSeparator(.hidden)
                    }
                    if m.threadsMore && m.query.isEmpty {
                        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                            .listRowSeparator(.hidden)
                            .onAppear { m.loadMoreThreads() }
                    }
                    if m.query.isEmpty { AppChatsHint(show: sms == .ready || sms == .off) }
                }
                .listStyle(.sidebar)
            }
        }
        .animation(.easeOut(duration: 0.2), value: rows.map(\.id))
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private func smsNotice(_ a: SmsAvailability, hasRows: Bool) -> some View {
        let m = model.messages
        switch a {
        case .off where hasRows:
            NoticeBar(icon: "message.badge", text: "Show texts here", tint: .accentColor) {
                Button("Turn On") { m.enableSms() }.controlSize(.small)
            }
        case .needsPermission where hasRows:
            NoticeBar(icon: "lock.shield", text: "Allow texts on your phone", tint: .orange) {
                Button("Ask on Phone") { m.askForPermission() }.controlSize(.small)
            }
        case .failed(let msg) where hasRows:
            NoticeBar(icon: "exclamationmark.triangle", text: msg, tint: .orange) {
                Button("Retry") { m.retryAfterFailure() }.controlSize(.small)
            }
        default: EmptyView()
        }
    }

    @ViewBuilder private func emptyState(_ a: SmsAvailability) -> some View {
        let m = model.messages
        if model.state.link != .connected {
            DisconnectedState(what: "Your conversations")
        } else if !model.state.settings.notifications && a == .off {
            smsOffState
        } else {
            switch a {
            case .off: smsOffState
            case .needsPermission:
                StateView(icon: "lock.shield", title: "Allow texts on your phone",
                          message: "One tap on your phone, then texts appear here.",
                          tint: .orange) { AskOnPhoneButton(kind: .sms) }
            case .loading:
                StateView(icon: "message", title: "Loading conversations", message: "From your phone\u{2026}", busy: true)
            case let .failed(msg):
                StateView(icon: "exclamationmark.triangle", title: "Couldn\u{2019}t load messages", message: msg, tint: .orange) {
                    Button("Try Again") { m.retryAfterFailure() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            case .ready:
                if m.query.isEmpty {
                    StateView(icon: "message", title: "No conversations yet",
                              message: "Texts from your phone appear here.") {
                        Button("New Message") { m.startNewMessage() }.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                } else {
                    StateView(icon: "magnifyingglass", title: "No results", message: "Nothing matches \u{201C}\(m.query)\u{201D}")
                }
            }
        }
    }

    private var smsOffState: some View {
        StateView(icon: "message.badge", title: "Messages on your Mac",
                  message: "Read and send texts from here.",
                  tint: .accentColor) {
            Button("Turn On Messages") { model.messages.enableSms() }.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}

/// Explains why app chats can look short.
struct AppChatsHint: View {
    var show: Bool
    var body: some View {
        if show {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text("App chats show notifications only")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .listRowSeparator(.hidden)
        }
    }
}

struct ChatRow: View {
    var chat: ChatSummary

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(chat.unread ? Color.accentColor : .clear).frame(width: 8, height: 8).padding(.top, 17)
                .accessibilityLabel(chat.unread ? "Unread" : "")
            ChatAvatar(chat: chat, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(chat.title).font(.system(size: 13, weight: chat.unread ? .bold : .semibold)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(DayLabel.listTime(chat.date)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(chat.snippet).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(2)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

// MARK: Thread pane

struct ThreadPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let m = model.messages
        Group {
            if m.composingNew {
                NewMessageView()
            } else if let id = m.selection, let chat = m.summary(for: id) {
                ThreadView(id: id, chat: chat).id(id)
            } else {
                StateView(icon: "bubble.left.and.bubble.right", title: m.selection == nil ? "Select a conversation" : "Conversation not found",
                          message: "Pick one, or start a new message.") {
                    Button("New Message") { m.startNewMessage() }.buttonStyle(.bordered).controlSize(.large)
                        .disabled(model.state.link != .connected)
                }
            }
        }
        .background(.background)
    }
}

struct ThreadView: View {
    @Environment(AppModel.self) private var model
    var id: ChatID
    var chat: ChatSummary
    @State private var atTop = false

    var body: some View {
        let m = model.messages
        let lines = m.lines(for: id)
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        topOfThread(lines)
                        ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                            let prev = i > 0 ? lines[i - 1] : nil
                            let next = i + 1 < lines.count ? lines[i + 1] : nil
                            if prev == nil || !Calendar.current.isDate(prev!.date, inSameDayAs: line.date) {
                                DaySeparator(date: line.date).padding(.top, prev == nil ? 6 : 14).padding(.bottom, 6)
                            }
                            BubbleRow(line: line, chat: chat, prev: prev, next: next, onRetry: { m.retry(line.id, in: id) },
                                      onDiscard: { m.discard(line.id) })
                                .id(line.id)
                        }
                        Color.clear.frame(height: 8).id("bottom")
                    }
                    .padding(.horizontal, 16)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: lines.last?.id) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                .overlay {
                    if lines.isEmpty { threadEmpty }
                }
            }
            Composer(id: id, chat: chat)
        }
    }

    @ViewBuilder private func topOfThread(_ lines: [ChatLine]) -> some View {
        let m = model.messages
        if case let .sms(t) = id {
            if m.loadingThreads.contains(t) {
                ProgressView().controlSize(.small).padding(.vertical, 10)
            } else if m.moreByThread[t] ?? false, !lines.isEmpty {
                Color.clear.frame(height: 1).onAppear { m.loadOlder(id) }
            }
        } else if chat.appName != nil, !lines.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text("Shows notifications only, so earlier messages can be missing")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 10).padding(.horizontal, 24)
        }
    }

    @ViewBuilder private var threadEmpty: some View {
        let m = model.messages
        if case let .sms(t) = id, m.loadingThreads.contains(t) {
            ProgressView().controlSize(.regular)
        } else {
            StateView(icon: "text.bubble", title: "No messages yet",
                      message: chat.appName != nil ? "New messages appear as they arrive." : "Say something.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ChatAvatar(chat: chat, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .barBackground()
    }

    private var subtitle: String {
        if let app = chat.appName { return chat.isGroup ? "Group \u{00B7} via \(app)" : "via \(app)" }
        if chat.isGroup { return chat.addresses.joined(separator: ", ") }
        let a = chat.addresses.first ?? ""
        return a == chat.title ? "Text message" : a
    }
}

struct DaySeparator: View {
    var date: Date
    var body: some View {
        HStack(spacing: 4) {
            Text(DayLabel.text(date)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(date.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Bubbles

struct BubbleRow: View {
    @Environment(\.colorScheme) private var scheme
    var line: ChatLine
    var chat: ChatSummary
    var prev: ChatLine?
    var next: ChatLine?
    var onRetry: () -> Void = {}
    var onDiscard: () -> Void = {}
    @State private var hover = false

    private func sameRun(_ a: ChatLine?, _ b: ChatLine) -> Bool {
        guard let a else { return false }
        return a.isMine == b.isMine && a.sender == b.sender && abs(a.date.timeIntervalSince(b.date)) < 5 * 60
            && Calendar.current.isDate(a.date, inSameDayAs: b.date)
    }

    var body: some View {
        let startsRun = !sameRun(prev, line)
        let endsRun = !sameRun(line, next ?? line) || next == nil
        VStack(alignment: line.isMine ? .trailing : .leading, spacing: 2) {
            if chat.isGroup, !line.isMine, startsRun, !line.sender.isEmpty {
                Text(line.sender).font(.system(size: 11, weight: .semibold)).foregroundStyle(senderColor(line.sender))
                    .padding(.leading, 12).padding(.top, 6)
            }
            HStack(spacing: 6) {
                if line.isMine { Spacer(minLength: 80) }
                if line.isMine { timeLabel }
                bubble
                if !line.isMine { timeLabel }
                if !line.isMine { Spacer(minLength: 80) }
            }
            switch line.status {
            case .pending:
                Text("Sending\u{2026}").font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.trailing, 6)
            case let .failed(why):
                HStack(spacing: 8) {
                    Label("Not delivered", systemImage: "exclamationmark.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(.red)
                    Text(why).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Button("Retry", action: onRetry).buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 11, weight: .medium))
                    Button("Delete", action: onDiscard).buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 11))
                }
                .padding(.trailing, 6)
            case .normal: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: line.isMine ? .trailing : .leading)
        .padding(.top, startsRun ? (prev == nil ? 0 : 7) : 1.5)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .contextMenu {
            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(line.text, forType: .string) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(line.isMine ? "You" : (line.sender.isEmpty ? chat.title : line.sender)): \(line.text)")
    }

    private var timeLabel: some View {
        Text(line.date.formatted(date: .omitted, time: .shortened))
            .font(.system(size: 10.5)).foregroundStyle(.secondary).opacity(hover ? 1 : 0).fixedSize()
    }

    private var bubble: some View {
        let mine = line.isMine
        return Text(line.text)
            .font(.system(size: 13.5))
            .foregroundStyle(mine ? Color.white : Color.primary)
            .textSelection(.enabled)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(mine ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(incoming),
                        in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .opacity(line.status == .pending ? 0.6 : 1)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var incoming: Color { scheme == .dark ? Color(white: 0.24) : Color(white: 0.905) }
    private func senderColor(_ s: String) -> Color { Color(hue: nameHue(s), saturation: 0.6, brightness: scheme == .dark ? 0.9 : 0.58) }
}

// MARK: Composer

struct Composer: View {
    @Environment(AppModel.self) private var model
    var id: ChatID
    var chat: ChatSummary
    @FocusState private var focused: Bool

    var body: some View {
        let m = model.messages
        let canReply: Bool = { if case .app = id { return m.replyTarget(for: id) != nil }; return true }()
        let connected = model.state.link == .connected
        let text = Binding(get: { m.draft(id) }, set: { m.setDraft(id, $0) })
        VStack(alignment: .leading, spacing: 4) {
            if let err = m.sendError[id] {
                Text(err).font(.system(size: 11.5)).foregroundStyle(.red).padding(.leading, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .app = id, !canReply, connected {
                Text("Reply after the next message arrives")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.leading, 6)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder(canReply), text: text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13.5)).lineLimit(1...6).focused($focused)
                    .onSubmit { m.send(in: id, text: text.wrappedValue) }
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .disabled(!canReply || !connected)
                Button { m.send(in: id, text: text.wrappedValue) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)).symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.45) : Color.accentColor)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canReply || !connected)
                .padding(.trailing, 3).padding(.bottom, 1.5)
                .help("Send")
            }
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(.primary.opacity(focused ? 0.18 : 0.08), lineWidth: 1))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onAppear { focused = true }
    }

    private func placeholder(_ canReply: Bool) -> String {
        if model.state.link != .connected { return "Phone not connected" }
        if !canReply { return "Can\u{2019}t reply right now" }
        if let app = chat.appName { return "Reply on \(app)" }
        return "Text Message \u{00B7} SMS"
    }
}

// MARK: New message

struct NewMessageView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var toFocused: Bool
    @FocusState private var bodyFocused: Bool

    var body: some View {
        @Bindable var m = model.messages
        let connected = model.state.link == .connected
        let suggestions = m.recipientSuggestions(for: m.newRecipients)
        VStack(spacing: 0) {
            HStack {
                Text("New Message").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel") { m.composingNew = false }.buttonStyle(.borderless).foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).barBackground()

            HStack(spacing: 8) {
                Text("To:").font(.system(size: 13)).foregroundStyle(.secondary)
                TextField("Phone number or name", text: $m.newRecipients)
                    .textFieldStyle(.plain).font(.system(size: 13.5)).focused($toFocused)
                    .onSubmit { bodyFocused = true }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider() }

            if let err = m.newMessageError {
                Text(err).font(.system(size: 12)).foregroundStyle(.red).padding(.horizontal, 16).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !suggestions.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        Text(m.newRecipients.isEmpty ? "Recent" : "Suggestions").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .textCase(.uppercase).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
                        ForEach(suggestions) { t in
                            Button {
                                var parts = m.newRecipients.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                                if !parts.isEmpty { parts.removeLast() }
                                parts.append(t.addresses.first ?? t.name)
                                m.newRecipients = parts.joined(separator: ", ")
                                bodyFocused = true
                            } label: {
                                HStack(spacing: 10) {
                                    Avatar(name: t.name, initials: ChatAvatar.initials(t.name), icon: t.avatar, size: 30)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(t.name).font(.system(size: 13, weight: .medium))
                                        if let a = t.addresses.first, a != t.name { Text(a).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16).padding(.vertical, 5).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if !connected { NoticeBar(icon: "iphone.gen3.slash", text: "Connect your phone to send a message") }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Text Message \u{00B7} SMS", text: $m.newText, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13.5)).lineLimit(1...6).focused($bodyFocused)
                    .onSubmit { m.sendNew() }
                    .padding(.horizontal, 13).padding(.vertical, 7)
                Button { m.sendNew() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)).symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(m.newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.45) : Color.accentColor)
                .disabled(m.newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !connected)
                .padding(.trailing, 3).padding(.bottom, 1.5)
            }
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .onAppear { toFocused = true }
    }
}
