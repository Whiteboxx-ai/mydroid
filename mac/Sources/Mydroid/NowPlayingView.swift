import SwiftUI
import AppKit
import CoreImage
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

/// Now Playing card: the phone's song with its cover, a quiet wash of the cover's colour, a progress bar with times and the controls.
/// The progress bar is extrapolated from `position`, `ts` and `playing`; no networking.
struct NowPlayingRow: View {
    var media: MediaState
    var command: (String) -> Void
    /// "Continue on Mac" (when the phone sent a `mediaId`) or "Search on web" (when it didn't). nil hides the button.
    var handoff: (() -> Void)?
    @State private var art: NSImage?
    @State private var tint: Color?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text("On your phone · \(media.displayApp)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    Text(media.title.isEmpty ? "Playing" : media.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if !media.artist.isEmpty {
                        Text(media.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            if media.duration > 0 {
                TimelineView(.animation(minimumInterval: 0.5, paused: !media.playing)) { ctx in
                    VStack(spacing: 3) {
                        ProgressStrip(fraction: media.fraction(at: ctx.date))
                        HStack {
                            Text(Self.clock(media.fraction(at: ctx.date) * Double(media.duration)))
                            Spacer()
                            Text("-" + Self.clock((1 - media.fraction(at: ctx.date)) * Double(media.duration)))
                        }
                        .font(.system(size: 10, design: .rounded).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                HStack(spacing: 4) {
                    control("backward.fill", "Previous", enabled: media.canPrev, size: 13) { command("prev") }
                    control(media.playing ? "pause.fill" : "play.fill", media.playing ? "Pause" : "Play", enabled: true, size: 18) { command("toggle") }
                    control("forward.fill", "Next", enabled: media.canNext, size: 13) { command("next") }
                }
                Spacer(minLength: 8)
                if let handoff, let offer = ContinueOnMac.offer(for: media) { HandoffButton(offer: offer, action: handoff) }
            }
        }
        .padding(12)
        .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill((tint ?? Color.primary).opacity(tint == nil ? 0.05 : 0.14)) }
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
        .accessibilityElement(children: .contain)
        .task(id: media.art) {
            guard let d = media.art else { art = nil; tint = nil; return }
            art = NSImage(data: d)
            tint = art.flatMap(Self.averageColor)
        }
    }

    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            if let art { Image(nsImage: art).resizable().scaledToFill() }
            else {
                let h = nameHue(media.displayApp)
                LinearGradient(colors: [Color(hue: h, saturation: 0.45, brightness: 0.9), Color(hue: h, saturation: 0.7, brightness: 0.65)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .onAppear { if art == nil, let d = media.art { art = NSImage(data: d); tint = art.flatMap(Self.averageColor) } }
    }

    private func control(_ symbol: String, _ label: String, enabled: Bool, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: 34, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.primary.opacity(0.3))
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    /// m:ss from milliseconds.
    static func clock(_ ms: Double) -> String {
        let t = max(0, Int(ms / 1000))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    /// The cover's average colour, for the quiet wash behind the card.
    static func averageColor(_ image: NSImage) -> Color? {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
        let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)])
        guard let out = f?.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return Color(.sRGB, red: Double(px[0]) / 255, green: Double(px[1]) / 255, blue: Double(px[2]) / 255)
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
                .background(Capsule().fill(isContinue ? Brand.accent.opacity(hover ? 0.24 : 0.16) : Color.primary.opacity(hover ? 0.12 : 0.07)))
                .foregroundStyle(isContinue ? Brand.accent : Color.primary.opacity(0.75))
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
