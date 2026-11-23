import SwiftUI
import MydroidCore

/// The incoming-call panel. Calls are answered on the phone; the audio stays there unless the user turned on Mac call audio,
/// in which case an audio switch (Phone / Mac) appears while the call is active.
struct CallView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let call = model.state.call {
                content(call)
            } else {
                Color.clear
            }
        }
        .frame(width: Self.width)
        // The panel is as tall as its content: the audio switch, meter and notes come and go.
        .fixedSize(horizontal: false, vertical: true)
    }

    static let width: CGFloat = 372

    @ViewBuilder
    private func content(_ call: CallInfo) -> some View {
        let answered = model.answeredCalls.contains(call.callId)
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Avatar(name: call.displayName, initials: call.initials, size: 52)
                    .overlay(alignment: .bottomTrailing) {
                        if call.phase == .ringing && call.incoming {
                            Image(systemName: "phone.fill").font(.system(size: 9)).padding(4)
                                .background(Color.green, in: Circle()).foregroundStyle(.white).offset(x: 3, y: 3)
                                .symbolEffect(.pulse)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(call.displayName).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: call.displayName)
                    subtitle(call, answered: answered)
                }
                Spacer(minLength: 0)
            }
            .overlay(alignment: .topTrailing) {
                if call.phase != .ended {
                    // Hide the panel without touching the call. It stays reachable from the menu bar.
                    Button { model.hideCallPanel() } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary).frame(width: 22, height: 22)
                            .background(.quaternary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(call.phase == .ringing && call.incoming ? "Ignore on this Mac (your phone keeps ringing)" : "Hide (the call continues)")
                    .offset(x: 4, y: -4)
                }
            }
            if call.phase == .active, model.callAudio.showsRouteSwitch {
                AudioRouteSwitch()
                if model.callAudio.routedToMac { RoutedAudioStatus() }
            }
            controls(call, answered: answered)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .padding(8)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: call.phase)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: answered)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: model.callAudio.route)
    }

    @ViewBuilder
    private func subtitle(_ call: CallInfo, answered: Bool) -> some View {
        switch call.phase {
        case .ringing:
            if answered {
                Label("Answering on your phone\u{2026}", systemImage: "iphone.gen3").font(.system(size: 12.5)).foregroundStyle(.secondary)
            } else {
                Text(call.incoming ? "Incoming cellular call" : "Calling from your phone\u{2026}").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        case .active:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(activeLine(call)).font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let t = Int(max(0, ctx.date.timeIntervalSince(call.startedAt)))
                    Text(String(format: "%d:%02d", t / 60, t % 60)).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
        case .ended:
            Text("Call ended").font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
    }

    private func activeLine(_ call: CallInfo) -> String {
        let audio = model.callAudio
        switch audio.route {
        case .mac: return audio.prefs.tier == .listen ? "Listening on your Mac" : "Audio is on your Mac"
        case let .switching(to): return to == .mac ? "Switching to your Mac\u{2026}" : "Switching to your phone\u{2026}"
        case .phone: return call.incoming ? "Answered \u{2014} audio is on your phone" : "Outgoing call \u{2014} audio is on your phone"
        }
    }

    @ViewBuilder
    private func controls(_ call: CallInfo, answered: Bool) -> some View {
        switch call.phase {
        case .ringing where call.incoming && !answered:
            HStack(spacing: 10) {
                CallButton(title: "Decline", symbol: "phone.down.fill", tint: .red) { model.hub.callAction("decline") }
                CallButton(title: "Answer", symbol: "phone.fill", tint: .green) {
                    model.answeredCalls.insert(call.callId)
                    model.hub.callAction("answer")
                }
            }
        case .ringing:
            HStack(spacing: 10) {
                CallButton(title: "End call", symbol: "phone.down.fill", tint: .red) { model.hub.callAction("end") }
            }
        case .active:
            HStack(spacing: 10) {
                CallButton(title: call.muted ? "Unmute" : "Mute", symbol: call.muted ? "mic.slash.fill" : "mic.fill",
                           tint: call.muted ? .orange : .gray) { model.hub.callAction(call.muted ? "unmute" : "mute") }
                CallButton(title: "End call", symbol: "phone.down.fill", tint: .red) { model.hub.callAction("end") }
            }
        default:
            EmptyView()
        }
    }
}

struct CallButton: View {
    var title: String
    var symbol: String
    var tint: Color
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13.5, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .foregroundStyle(.white)
                .background(tint.opacity(hover ? 1 : 0.9), in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
