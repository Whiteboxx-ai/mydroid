import SwiftUI
import AppKit
import MydroidCore
import MydroidNM

// "Set up Fill from phone in <Browser>": one browser at a time, large numbered steps, one short line each (PROTOCOL.md 14.3).

/// Where the sheet is. Each step finishes by itself or by its own button; the last one is detected (the extension says hello).
@MainActor @Observable
final class ExtensionSetupModel {
    enum Step: Int, Comparable { case connect = 1, openPage, devMode, add, done
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue } }

    let browser: ChromiumBrowser
    let installer: ExtensionInstaller
    private(set) var openedPage = false
    /// Chrome wouldn't open the address; it is on the clipboard and the browser is in front.
    private(set) var pasteFallback = false
    private(set) var devModeDone = false
    private(set) var copiedPath = false
    private(set) var opening = false
    /// Set to run the steps again for a browser that was already working.
    private(set) var again = false
    private let startedAt = Date()
    private let wasReady: Bool
    var copy: (String) -> Void = { s in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

    init(browser: ChromiumBrowser, installer: ExtensionInstaller) {
        self.browser = browser; self.installer = installer
        wasReady = installer.row(browser).ready
    }

    var helperAvailable: Bool { installer.helperAvailable }
    var connected: Bool { installer.row(browser).state == .installed }
    var folder: URL { installer.stableFolder }

    var ready: Bool {
        guard connected, let seen = installer.seenAt[browser.rawValue] else { return false }
        return again ? seen > startedAt : true
    }

    var current: Step {
        if ready { return .done }
        if !connected { return .connect }
        if !openedPage { return .openPage }
        if !devModeDone { return .devMode }
        return .add
    }

    /// Step 1 runs by itself.
    func start() { if !connected && helperAvailable { installer.install(browser) } }

    func setUpAgain() { again = true; openedPage = false; devModeDone = false; pasteFallback = false; start() }

    func openPage() async {
        guard !opening else { return }
        opening = true
        let ok = await installer.openExtensionsPage(browser)
        if !ok {
            pasteFallback = true
            copy(browser.extensionsPage)
            installer.bringForward(browser)
        }
        opening = false
        openedPage = true
    }

    func copyAddress() { copy(browser.extensionsPage) }
    func copyPath() { copy(folder.path); copiedPath = true }
    func showInFinder() { installer.revealExtensionFolder() }
    func devModeOn() { devModeDone = true }

    /// For renders: puts the sheet at a step without doing anything.
    func fixture(step: Step, fallback: Bool = false) {
        openedPage = step > .openPage; devModeDone = step > .devMode
        pasteFallback = fallback && step > .openPage
    }
}

struct ExtensionSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var setup: ExtensionSetupModel
    private var name: String { setup.browser.displayName }

    init(setup: ExtensionSetupModel) { _setup = State(initialValue: setup) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Set up Fill from phone in \(name)").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Close") { dismiss() }.controlSize(.small).keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 16)

            if setup.ready { ReadyPanel(setup: setup, onDone: { dismiss() }) } else { steps }
        }
        .padding(22)
        .frame(width: 480)
        .task { setup.start() }
    }

    private var steps: some View {
        let cur = setup.current
        return VStack(alignment: .leading, spacing: 4) {
            StepRow(number: 1, title: "Connect Mydroid to \(name)", step: .connect, current: cur) {
                if setup.helperAvailable {
                    Label("Connecting\u{2026}", systemImage: "link").font(.callout).foregroundStyle(.secondary)
                } else {
                    Label("Needs the installed app", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
            } done: { "Connected" }

            StepRow(number: 2, title: "Open \(name)\u{2019}s Extensions page", step: .openPage, current: cur) {
                Button { Task { await setup.openPage() } } label: { Text("Open Extensions Page").frame(minWidth: 150) }
                    .buttonStyle(SetupPrimaryButtonStyle()).disabled(setup.opening)
            } done: { "Opened" } note: {
                setup.pasteFallback ? "Copied. Paste it in the address bar (\u{2318}V)" : nil
            }

            StepRow(number: 3, title: "Turn on \u{201C}Developer mode\u{201D}", step: .devMode, current: cur) {
                VStack(alignment: .leading, spacing: 10) {
                    DeveloperModeIllustration()
                    Button("I turned it on") { setup.devModeOn() }.buttonStyle(SetupPrimaryButtonStyle())
                }
            } done: { "On" }

            StepRow(number: 4, title: "Add Mydroid", step: .add, current: cur) {
                AddStep(setup: setup, name: name)
            } done: { "Added" }
        }
        .animation(.smooth(duration: 0.25), value: cur)
    }
}

/// Drawn by hand so it looks the same whether or not its window is the key one.
struct SetupPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Brand.accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: Rows

private struct StepRow<Body: View>: View {
    let number: Int
    let title: String
    let step: ExtensionSetupModel.Step
    let current: ExtensionSetupModel.Step
    @ViewBuilder var content: () -> Body
    var done: () -> String
    /// A second line for a finished step that has something to say (the paste fallback).
    var note: () -> String? = { nil }

    private var isDone: Bool { current > step }
    private var isCurrent: Bool { current == step }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: isCurrent ? 15 : 13.5, weight: .semibold))
                        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                    if isDone { Text(done()).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1) }
                }
                .frame(minHeight: 26, alignment: .leading)
                if isDone, let n = note() {
                    Label(n, systemImage: "doc.on.clipboard").font(.system(size: 12.5)).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
                if isCurrent { content().transition(.opacity) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, isCurrent ? 12 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var badge: some View {
        ZStack {
            Circle().fill(isDone ? Color.green : (isCurrent ? Brand.accent : Color.clear))
            Circle().strokeBorder(Color.primary.opacity(isDone || isCurrent ? 0 : 0.25), lineWidth: 1.2)
            if isDone { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
            else { Text("\(number)").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(isCurrent ? Color.white : Color.secondary) }
        }
        .frame(width: 26, height: 26)
        .accessibilityLabel(isDone ? "Step \(number) done" : "Step \(number)")
    }
}

private struct AddStep: View {
    let setup: ExtensionSetupModel
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                FolderTile(url: setup.folder)
                Text("Drag this onto the page").font(.system(size: 13.5, weight: .medium))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Or click Load unpacked, press \u{2318}\u{21E7}G and paste").font(.system(size: 12.5)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button { setup.copyPath() } label: { Label(setup.copiedPath ? "Copied" : "Copy Path", systemImage: setup.copiedPath ? "checkmark" : "doc.on.doc") }
                    Button { setup.showInFinder() } label: { Label("Show in Finder", systemImage: "folder") }
                }
                .controlSize(.regular)
            }
            HStack(spacing: 8) {
                HUDSpinner(color: Brand.accent)
                Text("Waiting for \(name)\u{2026}").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }
}

/// The folder as a draggable tile: dropping it on the Extensions page loads the extension.
struct FolderTile: View {
    let url: URL

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 52, height: 52)
            Text("Browser Extension").font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Brand.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [5, 3])))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onDrag { NSItemProvider(object: url as NSURL) }
        .help("Drag onto the Extensions page")
        .accessibilityLabel("Browser Extension folder. Drag it onto the browser\u{2019}s Extensions page.")
    }

    private var icon: NSImage {
        let i = NSWorkspace.shared.icon(forFile: url.path)
        i.size = NSSize(width: 52, height: 52)
        return i
    }
}

/// A tiny drawing of the page's top-right corner with the toggle on, so nobody has to hunt for it.
struct DeveloperModeIllustration: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .textBackgroundColor))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("Extensions").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("Developer mode").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.primary)
                    Toggle(isOn: .constant(true)) { EmptyView() }.toggleStyle(MiniToggleStyle()).accessibilityHidden(true)
                }
                .padding(.horizontal, 10).frame(height: 30)
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.10)).frame(width: 120, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.06)).frame(width: 190, height: 5)
                }
                .padding(10)
            }
            Circle().strokeBorder(Brand.accent.opacity(0.9), lineWidth: 2).frame(width: 34, height: 34).offset(x: -3, y: -2)
        }
        .frame(width: 300, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The Developer mode switch is in the top-right corner of the Extensions page.")
    }
}

private struct MiniToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ZStack(alignment: configuration.isOn ? .trailing : .leading) {
            Capsule().fill(configuration.isOn ? Brand.accent : Color.primary.opacity(0.25)).frame(width: 28, height: 16)
            Circle().fill(.white).shadow(radius: 0.5).frame(width: 12, height: 12).padding(2)
        }
    }
}

private struct ReadyPanel: View {
    let setup: ExtensionSetupModel
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.green.opacity(0.16))
                Image(systemName: "checkmark").font(.system(size: 26, weight: .bold)).foregroundStyle(Color.green)
            }
            .frame(width: 64, height: 64)
            Text("Fill from phone is ready in \(setup.browser.displayName)").font(.system(size: 16, weight: .semibold)).multilineTextAlignment(.center)
            Text("A chip appears next to code fields").font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Set Up Again") { setup.setUpAgain() }.controlSize(.large)
                Button("Done", action: onDone).buttonStyle(SetupPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}
