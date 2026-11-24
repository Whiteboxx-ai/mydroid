import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import MydroidCore

// The camera window (PROTOCOL.md 14.4): live preview, a framing guide, the steps, batch progress, and the phone's answer.

/// The window's root: finds the controller the app model made and keeps it in step with the window and the phone link.
struct CameraImportRoot: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Group {
            if let c = model.cameraImport {
                CameraImportView(controller: c)
                    .onAppear { c.begin() }
                    .onChange(of: model.state.link) { _, link in c.phoneConnection(link == .connected) }
            } else {
                Color.clear.frame(width: CameraImportView.width, height: 200)
            }
        }
        .onDisappear { model.closeCameraImport() }
    }
}

struct CameraImportView: View {
    static let width: CGFloat = 480
    /// The preview is a mirror, like FaceTime. Detection never sees this: it reads the raw frames.
    static let mirrorsPreview = true
    var controller: CameraImportController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 18) {
            header
            stage
            progressRow
            steps
            footer
        }
        .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)
        .frame(width: Self.width)
        .background(.background)
        .animation(.smooth(duration: 0.25), value: controller.phase)
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "key.viewfinder")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Brand.accent)
                .frame(width: 52, height: 52)
                .background(Brand.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("Import from Google Authenticator").font(.system(size: 18, weight: .semibold))
            Text("Show the transfer codes to this Mac\u{2019}s camera.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var stage: some View {
        switch controller.phase {
        case .scanning, .askingForCamera: cameraStage
        case .approving: ResultPanel(symbol: "iphone.gen3", tint: Brand.accent, busy: true,
                                     title: "Approve on your phone\u{2026}",
                                     detail: "Check the list on your phone, then tap Add.")
        case .done(let added, let skipped): ResultPanel(symbol: "checkmark.circle.fill", tint: .green, busy: false,
                                                        title: Self.doneTitle(added: added, skipped: skipped),
                                                        detail: Self.doneDetail(added: added, skipped: skipped))
        case .failed(let f): ResultPanel(symbol: "exclamationmark.triangle.fill", tint: .orange, busy: false, title: f.title, detail: f.detail)
        case .offline: ResultPanel(symbol: "iphone.slash", tint: .secondary, busy: false, title: "Your phone isn\u{2019}t connected",
                                   detail: "Scanning starts once it is.")
        case .cameraDenied: ResultPanel(symbol: "video.slash.fill", tint: .orange, busy: false, title: "Camera access is off",
                                        detail: "Allow Mydroid in Privacy & Security \u{203A} Camera. Nothing is recorded.")
        case .noCamera: ResultPanel(symbol: "video.slash.fill", tint: .secondary, busy: false, title: "No camera found",
                                    detail: "Connect a camera, or add accounts on your phone.")
        }
    }

    private var cameraStage: some View {
        ZStack {
            Color.black
            // Shown mirrored, like FaceTime and Photo Booth, so moving a hand left moves it left on screen. Vision still reads the raw frames.
            if let still = controller.camera.stillPreview {
                Image(nsImage: still).resizable().scaledToFill().mirrored(Self.mirrorsPreview)
            } else if let session = controller.camera.session {
                CameraPreview(session: session)
            }
            if controller.phase == .askingForCamera {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Waiting for camera access\u{2026}").font(.callout).foregroundStyle(.white.opacity(0.85))
                }
            } else {
                FramingGuide(active: controller.progress != nil).mirrored(Self.mirrorsPreview)
            }
            VStack {
                Spacer()
                if let hint = controller.hint {
                    Text(hint)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(.bottom, 12).padding(.horizontal, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(height: 290)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .animation(.smooth(duration: 0.2), value: controller.hint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Camera preview. Hold your phone\u{2019}s transfer code in front of the camera.")
    }

    @ViewBuilder private var progressRow: some View {
        switch controller.phase {
        case .scanning, .askingForCamera:
            VStack(spacing: 6) {
                if let p = controller.progress {
                    HStack(spacing: 5) {
                        ForEach(0..<p.total, id: \.self) { i in
                            Capsule().fill(i < p.scanned ? Brand.accent : Color.primary.opacity(0.15)).frame(height: 5)
                        }
                    }
                    .frame(maxWidth: 220)
                    .accessibilityHidden(true)
                    Text("\(p.scanned) of \(p.total) scanned").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    if p.scanned < p.total {
                        Text("Tap Next on your phone for the next code").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Looking for a transfer code\u{2026}").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 40)
        default:
            EmptyView()
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Step(n: 1) {
                Text("In Google Authenticator: ") + Text("\u{22EE}").bold() + Text(" \u{2192} Transfer accounts \u{2192} Export")
            }
            Step(n: 2) { Text("Hold your phone up to the camera, screen bright") }
            Step(n: 3) { Text("Several codes? Tap Next on your phone for each") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(isFinished ? 0 : 1)             // keeps the window the same height; the steps are no use once it is sent
        .accessibilityHidden(isFinished)
    }

    private var isFinished: Bool {
        switch controller.phase { case .done, .approving: return true; default: return false }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(footerText).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            switch controller.phase {
            case .done:
                Button("Done") { NSApp.keyWindow?.close() }.keyboardShortcut(.defaultAction)
            case .failed, .noCamera:
                Button("Close") { NSApp.keyWindow?.close() }
                if controller.phase != .noCamera { Button("Scan Again") { controller.begin() }.keyboardShortcut(.defaultAction) }
            case .cameraDenied:
                Button("Close") { NSApp.keyWindow?.close() }
                Button("Open Privacy Settings") { Self.openCameraPrivacy() }.keyboardShortcut(.defaultAction)
            default:
                Button("Cancel") { NSApp.keyWindow?.close() }.keyboardShortcut(.cancelAction)
            }
        }
        .controlSize(.regular)
    }

    private var footerText: String {
        switch controller.phase {
        case .done, .approving: return "The camera is off."
        case .failed: return "Nothing was saved on this Mac."
        default: return "Nothing is saved on this Mac."
        }
    }

    static func openCameraPrivacy() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(u) }
    }

    static func doneTitle(added: Int, skipped: Int) -> String {
        if added == 0 { return skipped > 0 ? "Already on your phone" : "Nothing new to add" }
        return "Added \(added) \(added == 1 ? "account" : "accounts") on your phone"
    }

    static func doneDetail(added: Int, skipped: Int) -> String {
        var s = "Nothing was saved on this Mac."
        if skipped > 0, added > 0 { s += " \(skipped) \(skipped == 1 ? "was" : "were") already there." }
        return s
    }
}

private struct Step<Content: View>: View {
    let n: Int
    @ViewBuilder var content: Content
    init(n: Int, @ViewBuilder _ content: () -> Content) { self.n = n; self.content = content() }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Brand.accent, in: Circle())
            content.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// The big message that replaces the camera: approve, done, error, no phone, no permission.
private struct ResultPanel: View {
    var symbol: String
    var tint: Color
    var busy: Bool
    var title: String
    var detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 44, weight: .regular)).foregroundStyle(tint).symbolRenderingMode(.hierarchical)
                .frame(height: 56)
            Text(title).font(.system(size: 17, weight: .semibold)).multilineTextAlignment(.center)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 24)
            if busy { ProgressView().controlSize(.small).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity).frame(height: 290)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Flips the picture left to right (a mirror), for a preview only.
    @ViewBuilder func mirrored(_ on: Bool) -> some View { if on { scaleEffect(x: -1, y: 1, anchor: .center) } else { self } }
}

/// Four corner brackets and a soft vignette. Turns accent-coloured once the first part has been read.
private struct FramingGuide: View {
    var active: Bool
    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height) * 0.72
            let rect = CGRect(x: (g.size.width - side) / 2, y: (g.size.height - side) / 2 - 6, width: side, height: side)
            ZStack {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: g.size))
                    p.addRoundedRect(in: rect, cornerSize: CGSize(width: 18, height: 18), style: .continuous)
                }
                .fill(.black.opacity(0.3), style: FillStyle(eoFill: true))
                CornerBrackets(rect: rect, length: 34, radius: 18)
                    .stroke(active ? Brand.accent : .white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .shadow(color: .black.opacity(0.35), radius: 3)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct CornerBrackets: Shape {
    var rect: CGRect
    var length: CGFloat
    var radius: CGFloat
    func path(in _: CGRect) -> Path {
        var p = Path()
        let r = radius, l = length
        let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        // top left
        p.move(to: CGPoint(x: x0, y: y0 + l)); p.addLine(to: CGPoint(x: x0, y: y0 + r))
        p.addQuadCurve(to: CGPoint(x: x0 + r, y: y0), control: CGPoint(x: x0, y: y0)); p.addLine(to: CGPoint(x: x0 + l, y: y0))
        // top right
        p.move(to: CGPoint(x: x1 - l, y: y0)); p.addLine(to: CGPoint(x: x1 - r, y: y0))
        p.addQuadCurve(to: CGPoint(x: x1, y: y0 + r), control: CGPoint(x: x1, y: y0)); p.addLine(to: CGPoint(x: x1, y: y0 + l))
        // bottom right
        p.move(to: CGPoint(x: x1, y: y1 - l)); p.addLine(to: CGPoint(x: x1, y: y1 - r))
        p.addQuadCurve(to: CGPoint(x: x1 - r, y: y1), control: CGPoint(x: x1, y: y1)); p.addLine(to: CGPoint(x: x1 - l, y: y1))
        // bottom left
        p.move(to: CGPoint(x: x0 + l, y: y1)); p.addLine(to: CGPoint(x: x0 + r, y: y1))
        p.addQuadCurve(to: CGPoint(x: x0, y: y1 - r), control: CGPoint(x: x0, y: y1)); p.addLine(to: CGPoint(x: x0, y: y1 - l))
        return p
    }
}

/// The live camera, mirrored. Only this preview is flipped: Vision reads the video output's own, unmirrored frames.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.applyMirror()
        return v
    }
    func updateNSView(_ v: PreviewView, context: Context) {
        if v.previewLayer.session !== session { v.previewLayer.session = session }
        v.applyMirror()
    }
    static func dismantleNSView(_ v: PreviewView, coordinator: ()) { v.stopObserving(); v.previewLayer.session = nil }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        private var observer: NSObjectProtocol?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true; layer = previewLayer
            // The layer's connection only exists once the session has its input, which is after this view is made.
            observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyMirror() }
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        func stopObserving() { if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil }
        override func layout() { super.layout(); applyMirror() }

        func applyMirror() {
            guard let c = previewLayer.connection, c.isVideoMirroringSupported else { return }
            if c.automaticallyAdjustsVideoMirroring { c.automaticallyAdjustsVideoMirroring = false }
            if !c.isVideoMirrored { c.isVideoMirrored = true }
        }
    }
}
