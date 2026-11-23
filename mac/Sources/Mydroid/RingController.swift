import SwiftUI
import AppKit
import MydroidCore

// PROTOCOL.md 11, "Ring": a loud repeating sound and a floating panel with Stop, until stopped or 60 seconds.

protocol RingSounding: AnyObject {
    func start()
    func stop()
}

@MainActor
protocol RingPanelPresenting: AnyObject {
    func show(stop: @escaping () -> Void)
    func hide()
}

/// Plays a system alert sound on a loop.
final class SystemRingSound: RingSounding {
    private var sound: NSSound?
    func start() {
        let s = NSSound(contentsOfFile: "/System/Library/Sounds/Sosumi.aiff", byReference: true) ?? NSSound(named: "Funk")
        s?.loops = true
        s?.play()
        sound = s
    }
    func stop() { sound?.stop(); sound = nil }
}

@MainActor @Observable
final class RingController: RingControlling {
    private(set) var isRinging = false
    /// When the ring will stop by itself.
    private(set) var endsAt: Date?

    @ObservationIgnored private let sound: RingSounding
    @ObservationIgnored private let volume: VolumeControlling
    @ObservationIgnored private let panel: RingPanelPresenting
    @ObservationIgnored private let waker: DisplayWaking
    @ObservationIgnored private let duration: TimeInterval
    @ObservationIgnored private var saved: VolumeSnapshot?
    @ObservationIgnored private var stopWork: DispatchWorkItem?

    /// The ring stops by itself after this long (PROTOCOL.md 11).
    nonisolated static let defaultDuration: TimeInterval = 60

    init(sound: RingSounding, volume: VolumeControlling, panel: RingPanelPresenting, waker: DisplayWaking,
         duration: TimeInterval = 60) {
        self.sound = sound; self.volume = volume; self.panel = panel; self.waker = waker; self.duration = duration
    }

    /// The real thing: system sound, system volume, a floating panel.
    convenience init() {
        self.init(sound: SystemRingSound(), volume: SystemVolume(), panel: RingPanelController(), waker: UserActivityWaker())
    }

    // The protocol is callable from any thread (the Hub's queue); the work happens on the main actor.
    nonisolated func startRinging() { Task { @MainActor in self.start() } }
    nonisolated func stopRinging() { Task { @MainActor in self.stop() } }

    func start() {
        if !isRinging {
            isRinging = true
            saved = volume.boost()                 // the loud part: full volume, unmuted, put back on stop
            waker.wake()                           // so the panel is on a lit screen
            sound.start()
            panel.show(stop: { [weak self] in self?.stop() })
        }
        endsAt = Date().addingTimeInterval(duration)
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.stop() } }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func stop() {
        stopWork?.cancel(); stopWork = nil
        guard isRinging else { return }
        isRinging = false
        endsAt = nil
        sound.stop()
        if let saved { volume.restore(saved) }
        saved = nil
        panel.hide()
    }
}

// MARK: Panel

struct RingPanelView: View {
    var stop: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.orange, .red.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                Image(systemName: "bell.and.waves.left.and.right.fill")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your phone is looking for this Mac").font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text("Ringing for up to a minute").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button(action: stop) { Text("Stop").font(.system(size: 12.5, weight: .semibold)).frame(minWidth: 40) }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .frame(width: RingPanelController.width - 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .padding(6)
    }
}

@MainActor
final class RingPanelController: RingPanelPresenting {
    static let width: CGFloat = 452
    private var panel: FloatingPanel?

    func show(stop: @escaping () -> Void) {
        guard panel == nil else { return }
        let size = NSSize(width: Self.width, height: 84)
        let p = FloatingPanel(size: size)
        let host = NSHostingView(rootView: RingPanelView(stop: stop))
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        let s = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let target = NSRect(x: s.midX - size.width / 2, y: s.maxY - size.height - 12, width: size.width, height: size.height)
        p.setFrame(target.offsetBy(dx: 0, dy: 24), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            p.animator().setFrame(target, display: true)
            p.animator().alphaValue = 1
        }
        panel = p
    }

    func hide() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }
}
