import SwiftUI
import AppKit
import MydroidCore

extension Color {
    /// The app's sky-blue, matching the app icon.
    static let brand = Color(red: 2 / 255, green: 132 / 255, blue: 199 / 255)
}

/// Initials avatar with a stable per-name gradient, or the notification's own icon when present.
struct Avatar: View {
    var name: String
    var initials: String
    var icon: Data? = nil
    var size: CGFloat = 36

    init(notification n: PhoneNotification, size: CGFloat = 36) {
        name = n.title.isEmpty ? n.app : n.title
        initials = n.initials
        icon = n.icon
        self.size = size
    }
    init(name: String, initials: String, icon: Data? = nil, size: CGFloat = 36) {
        self.name = name; self.initials = initials; self.icon = icon; self.size = size
    }

    private var hue: Double {
        var h: UInt32 = 5381
        for u in name.unicodeScalars { h = h &* 33 &+ u.value }
        return Double(h % 360) / 360
    }

    var body: some View {
        ZStack {
            if let icon, let img = NSImage(data: icon) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.92),
                                        Color(hue: hue, saturation: 0.75, brightness: 0.72)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(initials).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

struct BatteryView: View {
    var level: Int
    var charging: Bool
    var lowPower = false
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(level <= 15 && !charging ? Color.red : (charging ? Color.green : (lowPower ? Color.yellow : Color.secondary)))
            Text("\(level)%").font(.system(size: 11.5, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(level) percent\(charging ? ", charging" : "")\(lowPower ? ", battery saver on" : "")")
    }
    private var symbol: String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct PressableTileStyle: ButtonStyle {
    var active = false
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hover ? 0.10 : 0.06))
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

enum Fmt {
    static func relative(_ d: Date, now: Date = Date(), style: Date.RelativeFormatStyle.UnitsStyle = .abbreviated) -> String {
        if now.timeIntervalSince(d) < 45 { return "now" }
        return d.formatted(.relative(presentation: .numeric, unitsStyle: style))
    }
    /// "4 min ago"
    static func lastSeen(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "just now" }
        return d.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
            .replacingOccurrences(of: "minutes", with: "min").replacingOccurrences(of: "minute", with: "min")
    }
}

func thumbnail(for url: URL, maxPixel: Int = 160) -> NSImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceCreateThumbnailWithTransform: true,
                                 kCGImageSourceThumbnailMaxPixelSize: maxPixel]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

// MARK: Compact settings building blocks

/// A small ⓘ that holds the detail a row doesn't need to show: a popover (and tooltip) of at most three short sentences.
struct InfoButton: View {
    var text: String
    @State private var shown = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").imageScale(.small).foregroundStyle(.secondary).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("More information")
        .accessibilityHint(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 250, alignment: .leading)
                .padding(12)
        }
    }
}

/// A row label with an optional icon and an ⓘ after it.
struct InfoLabel: View {
    var title: String
    var icon: String? = nil
    var info: String? = nil

    init(_ title: String, icon: String? = nil, info: String? = nil) { self.title = title; self.icon = icon; self.info = info }

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Label(title, systemImage: icon) } else { Text(title) }
            if let info { InfoButton(info) }
        }
    }
}

/// A switch row (label, optional ⓘ, trailing switch), the System Settings way.
struct InfoToggle: View {
    var title: String
    @Binding var isOn: Bool
    var info: String? = nil

    init(_ title: String, isOn: Binding<Bool>, info: String? = nil) { self.title = title; _isOn = isOn; self.info = info }

    var body: some View {
        LabeledContent {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
        } label: { InfoLabel(title, info: info) }
    }
}

/// A colored dot and a short status, the trailing half of a status row.
struct StatusText: View {
    var text: String
    var color: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A one-line, left-aligned note under a section (System Settings footer style).
struct FooterNote: View {
    var text: String
    var icon: String? = nil
    init(_ text: String, icon: String? = nil) { self.text = text; self.icon = icon }
    var body: some View {
        Group {
            if let icon { Label(text, systemImage: icon) } else { Text(text) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }
}
