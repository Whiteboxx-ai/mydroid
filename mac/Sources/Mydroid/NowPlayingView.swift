import SwiftUI
import AppKit
import MydroidCore

/// Popover section: shows the row only while the phone has an active media session.
struct NowPlayingSection: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.state.link == .connected, model.state.settings.media, let m = model.state.media {
            NowPlayingRow(media: m, command: model.mediaCommand, handoff: { model.continueOnMac(m) })
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }
}

/// Compact Now Playing row. The progress bar is extrapolated from `position`, `ts` and `playing`; no networking.
struct NowPlayingRow: View {
    var media: MediaState
    var command: (String) -> Void
    /// "Continue on Mac" (when the phone sent a `mediaId`) or "Search on web" (when it didn't). nil hides the button.
    var handoff: (() -> Void)?
    @State private var art: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                artwork
                VStack(alignment: .leading, spacing: 1) {
                    Text(media.title.isEmpty ? "Playing" : media.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if !media.artist.isEmpty {
                        Text(media.artist).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(media.displayApp).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    control("backward.fill", "Previous", enabled: media.canPrev, size: 12) { command("prev") }
                    control(media.playing ? "pause.fill" : "play.fill", media.playing ? "Pause" : "Play", enabled: true, size: 16) { command("toggle") }
                    control("forward.fill", "Next", enabled: media.canNext, size: 12) { command("next") }
                }
            }
            if media.duration > 0 {
                TimelineView(.animation(minimumInterval: 0.5, paused: !media.playing)) { ctx in
                    ProgressStrip(fraction: media.fraction(at: ctx.date))
                }
            }
            if let handoff, let offer = ContinueOnMac.offer(for: media) {
                HStack {
                    HandoffButton(offer: offer, action: handoff)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .card(0.05)
        .accessibilityElement(children: .contain)
        .task(id: media.art) {
            guard let d = media.art else { art = nil; return }
            art = NSImage(data: d)
        }
    }

    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return ZStack {
            if let art { Image(nsImage: art).resizable().scaledToFill() }
            else {
                let h = nameHue(media.displayApp)
                LinearGradient(colors: [Color(hue: h, saturation: 0.45, brightness: 0.9), Color(hue: h, saturation: 0.7, brightness: 0.65)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").font(.system(size: 17, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
        .onAppear { if art == nil, let d = media.art { art = NSImage(data: d) } }
    }

    private func control(_ symbol: String, _ label: String, enabled: Bool, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.primary.opacity(0.3))
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The small pill under the controls: Continue on Mac, or Search on web.
struct HandoffButton: View {
    var offer: ContinueOnMac.Offer
    var action: () -> Void
    @State private var hover = false

    private var isContinue: Bool { if case .continueOnMac = offer { return true }; return false }

    var body: some View {
        Button(action: action) {
            Label(isContinue ? "Continue on Mac" : "Search on web",
                  systemImage: isContinue ? "laptopcomputer.and.iphone" : "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(isContinue ? Color.accentColor.opacity(hover ? 0.24 : 0.16) : Color.primary.opacity(hover ? 0.12 : 0.07)))
                .foregroundStyle(isContinue ? Color.accentColor : Color.primary.opacity(0.75))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(isContinue ? "Play this on your Mac from the same spot" : "Search the web for this song")
        .accessibilityLabel(isContinue ? "Continue on Mac" : "Search on web")
    }
}

struct ProgressStrip: View {
    var fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(Color.primary.opacity(0.55)).frame(width: max(0, g.size.width * fraction))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}
