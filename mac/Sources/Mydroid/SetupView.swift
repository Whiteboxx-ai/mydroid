import SwiftUI
import MydroidCore

struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(step: model.setupStep).padding(.top, 28).padding(.bottom, 8)
            ZStack {
                switch model.setupStep {
                case .scan: ScanStep().transition(stepTransition)
                case .confirm: ConfirmStep().transition(stepTransition)
                case .choose: ChooseStep().transition(stepTransition)
                case .done: DoneStep().transition(stepTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(duration: 0.55, bounce: 0.18), value: model.setupStep)
        }
        .frame(width: 520, height: 560)
        .background(.background)
        .onAppear { if model.setupStep == .scan { model.hub.startPairing() } }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity))
    }
}

struct StepIndicator: View {
    var step: SetupStep
    private let labels = ["Scan", "Confirm", "Choose what to sync"]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                let current = min(step.rawValue, 2)
                let done = step == .done || i < current
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(done || i == current ? Color.brand : Color.primary.opacity(0.12)).frame(width: 18, height: 18)
                        if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                        else { Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(i == current ? .white : .secondary) }
                    }
                    Text(labels[i]).font(.system(size: 12, weight: i == current && step != .done ? .semibold : .regular))
                        .foregroundStyle(i == current && step != .done ? .primary : .secondary)
                }
                if i < 2 { Text("\u{00B7}").foregroundStyle(.tertiary) }
            }
        }
        .animation(.spring(duration: 0.4), value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(min(step.rawValue, 2) + 1) of 3")
    }
}

struct StepHeader: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
    }
}

struct ScanStep: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 22) {
            StepHeader(title: "Pair your Android", subtitle: "Open Mydroid on your phone and scan this code.")
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white)
                    .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
                if let url = model.state.pairing?.url, let img = QRCode.image(for: url) {
                    Image(nsImage: img).interpolation(.none).resizable().scaledToFit().padding(20)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .id(url)
                } else if let err = model.state.listenerError {
                    VStack(spacing: 6) {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 28)).foregroundStyle(.orange)
                        Text(err).font(.caption).foregroundStyle(.black.opacity(0.6)).multilineTextAlignment(.center)
                    }.padding(24)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(width: 244, height: 244)
            .animation(.spring(duration: 0.5), value: model.state.pairing?.url)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for your phone\u{2026}").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Text("Same Wi\u{2011}Fi as your Mac").font(.system(size: 12)).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }
}

struct ConfirmStep: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let phone = model.state.pairing?.phoneName ?? "phone"
        let code = MydroidCrypto.displayCode(model.state.pairing?.confirmCode ?? "000000")
        VStack(spacing: 26) {
            StepHeader(title: "Is this your \(phone)?", subtitle: "Check that the same code appears on both devices.")
            Text(code)
                .font(.system(size: 64, weight: .semibold, design: .rounded)).monospacedDigit().tracking(2)
                .padding(.horizontal, 34).padding(.vertical, 18)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .contentTransition(.numericText())
                .accessibilityLabel("Code \(code)")
            VStack(spacing: 10) {
                Button { model.codesMatch() } label: {
                    Text("Codes match").font(.system(size: 15, weight: .semibold)).frame(width: 220)
                }
                .buttonStyle(.borderedProminent).controlSize(.extraLarge).keyboardShortcut(.defaultAction)
                Button("Scan again") { model.scanAgain() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }
}

struct ChooseStep: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 18) {
            StepHeader(title: "What comes over?",
                       subtitle: "Pick what you want on this Mac.")
            VStack(spacing: 0) {
                FeatureToggle(symbol: "bell.badge.fill", tint: .red, title: "Notifications",
                              detail: "See messages and reply from your Mac.", key: \.notifications)
                Divider().padding(.leading, 56)
                FeatureToggle(symbol: "photo.on.rectangle.angled", tint: .purple, title: "Camera roll",
                              detail: "Save new photos to this Mac.", key: \.photos)
                Divider().padding(.leading, 56)
                FeatureToggle(symbol: "phone.fill", tint: .green, title: "Calls",
                              detail: "Ring on your Mac too.", key: \.calls)
                Divider().padding(.leading, 56)
                FeatureToggle(symbol: "doc.on.clipboard.fill", tint: .orange, title: "Clipboard",
                              detail: "Copy on one, paste on the other.", key: \.clipboard)
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 36)
            Button { model.finishChoices() } label: {
                Text("Continue").font(.system(size: 15, weight: .semibold)).frame(width: 220)
            }
            .buttonStyle(.borderedProminent).controlSize(.extraLarge).keyboardShortcut(.defaultAction)
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }
}

struct FeatureToggle: View {
    @Environment(AppModel.self) private var model
    var symbol: String
    var tint: Color
    var title: String
    var detail: String
    var key: WritableKeyPath<SyncSettings, Bool>
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.state.settings[keyPath: key] }, set: { model.setSetting(key, $0) }))
                .labelsHidden().toggleStyle(.switch)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

struct DoneStep: View {
    @Environment(AppModel.self) private var model
    @State private var appeared = false
    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            ZStack {
                Circle().fill(Color.green.opacity(0.15)).frame(width: 112, height: 112)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                    .symbolEffect(.bounce, value: appeared)
            }
            .scaleEffect(appeared ? 1 : 0.6).opacity(appeared ? 1 : 0)
            StepHeader(title: "Your \(model.phoneName) is connected",
                       subtitle: "Find Mydroid in your menu bar.")
            Button { model.closeSetup() } label: {
                Text("Open Mydroid").font(.system(size: 15, weight: .semibold)).frame(width: 220)
            }
            .buttonStyle(.borderedProminent).controlSize(.extraLarge).keyboardShortcut(.defaultAction)
            Spacer(minLength: 0)
        }
        .onAppear { withAnimation(.spring(duration: 0.7, bounce: 0.4).delay(0.1)) { appeared = true } }
    }
}
