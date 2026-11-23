import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MydroidCore

// PROTOCOL.md 14.3, "Global shortcut": read the front browser's address, ask the phone for the code, and type it only if the
// page is still on that site. The HUD shows each step. Nothing here logs a code, an issuer or an account.

// MARK: Shortcut key

/// A shortcut as Carbon wants it, plus the character to show.
struct AuthShortcutKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    static let standard = AuthShortcutKey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | optionKey), label: "C")

    var display: String {
        (modifiers & UInt32(controlKey) != 0 ? "\u{2303}" : "") + (modifiers & UInt32(optionKey) != 0 ? "\u{2325}" : "")
            + (modifiers & UInt32(shiftKey) != 0 ? "\u{21E7}" : "") + (modifiers & UInt32(cmdKey) != 0 ? "\u{2318}" : "") + label
    }

    /// From a key press while recording. Needs Control, Option or Command so it can't swallow ordinary typing.
    static func from(event: NSEvent) -> AuthShortcutKey? {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if f.contains(.control) { mods |= UInt32(controlKey) }
        if f.contains(.option) { mods |= UInt32(optionKey) }
        if f.contains(.command) { mods |= UInt32(cmdKey) }
        guard mods != 0 else { return nil }
        if f.contains(.shift) { mods |= UInt32(shiftKey) }
        guard let ch = event.charactersIgnoringModifiers?.uppercased(), let first = ch.first, first.isLetter || first.isNumber || first.isPunctuation || first.isSymbol else { return nil }
        return AuthShortcutKey(keyCode: UInt32(event.keyCode), modifiers: mods, label: String(first))
    }
}

// MARK: Browsers

struct FrontBrowser: Equatable {
    let bundleID: String
    let name: String
    /// AppleScript that returns the address of the current tab.
    let script: String

    private static func chromium(_ id: String, _ name: String) -> FrontBrowser {
        FrontBrowser(bundleID: id, name: name, script: "tell application id \"\(id)\" to return URL of active tab of front window")
    }
    private static func safari(_ id: String, _ name: String) -> FrontBrowser {
        FrontBrowser(bundleID: id, name: name, script: "tell application id \"\(id)\" to return URL of current tab of front window")
    }

    static let supported: [FrontBrowser] = [
        safari("com.apple.Safari", "Safari"), safari("com.apple.SafariTechnologyPreview", "Safari Technology Preview"),
        chromium("com.google.Chrome", "Chrome"), chromium("com.microsoft.edgemac", "Edge"), chromium("com.brave.Browser", "Brave"),
        chromium("company.thebrowser.Browser", "Arc"), chromium("org.chromium.Chromium", "Chromium"),
    ]

    static func match(bundleID: String?) -> FrontBrowser? { supported.first { $0.bundleID == bundleID } }
}

enum FrontApp: Equatable {
    case browser(FrontBrowser)
    case other(name: String?)
}

enum BrowserURLResult: Equatable {
    case url(URL)
    case automationDenied
    case unavailable
}

@MainActor
protocol FrontBrowserProviding: AnyObject {
    func frontmost() -> FrontApp
    func currentURL(of browser: FrontBrowser) async -> BrowserURLResult
}

/// Reads the front browser's address with AppleScript (needs Automation permission for that browser, asked once by macOS).
@MainActor
final class SystemFrontBrowser: FrontBrowserProviding {
    func frontmost() -> FrontApp {
        let app = NSWorkspace.shared.frontmostApplication
        if let b = FrontBrowser.match(bundleID: app?.bundleIdentifier) { return .browser(b) }
        return .other(name: app?.localizedName)
    }

    func currentURL(of b: FrontBrowser) async -> BrowserURLResult {
        // Asks the user the first time (blocks until they answer), so it runs off the main thread.
        let status = await Task.detached(priority: .userInitiated) { Self.automationStatus(bundleID: b.bundleID) }.value
        if status == OSStatus(errAEEventNotPermitted) { return .automationDenied }
        if status != noErr { return .unavailable }
        var error: NSDictionary?
        guard let out = NSAppleScript(source: b.script)?.executeAndReturnError(&error) else {
            let code = (error?[NSAppleScript.errorNumber] as? Int) ?? 0
            return code == -1743 ? .automationDenied : .unavailable
        }
        guard let s = out.stringValue, let u = URL(string: s) else { return .unavailable }
        return .url(u)
    }

    nonisolated static func automationStatus(bundleID: String) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, true)
    }

    static func openAutomationSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(u) }
    }
}

/// The page a code is for.
struct AuthSite: Equatable {
    var host: String
    var domain: String

    /// https pages only (plus http on this Mac, for development).
    init?(url: URL, psl: PublicSuffixList = .shared) {
        guard let scheme = url.scheme?.lowercased(), let raw = url.host, let h = PublicSuffixList.normalizeHost(raw) else { return nil }
        let local = h == "localhost" || h == "127.0.0.1"
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        host = h
        domain = psl.registrableDomain(of: h) ?? h
    }
}

// MARK: Typing

@MainActor
protocol CodeTyping: AnyObject {
    func type(_ code: String) async
}

/// Types digits with `CGEvent` (needs Accessibility), one key at a time so split boxes and fast pages keep up.
@MainActor
final class CGEventCodeTyper: CodeTyping {
    private let poster = CGEventPoster()
    func type(_ code: String) async {
        for ch in code {
            poster.post(.unicode(String(ch), flags: []))
            try? await Task.sleep(nanoseconds: 14_000_000)
        }
    }
}

// MARK: HUD state

struct AuthHUDActions {
    var cancel: () -> Void = {}
    var proceed: () -> Void = {}
    var startLink: () -> Void = {}
    var pick: (String) -> Void = { _ in }
    var confirmLookalike: () -> Void = {}
    var openAccessibility: () -> Void = {}
    var openAutomation: () -> Void = {}
}

enum AuthHUDState: Equatable {
    case explainAutomation(browser: String)
    case needsAutomation(browser: String)
    case needsAccessibility
    case unsupportedApp(String?)
    case noPage
    /// Talking to the phone before the approval is asked (the account list).
    case asking
    case waiting(domain: String)
    case filled(domain: String)
    case denied, timedOut, locked, offline, pageChanged, failed
    case noMatch(domain: String)
    case link(domain: String, entries: [AuthEntry])
    case linkConfirm(domain: String, entry: AuthEntry, lookalike: Lookalike)
    case ambiguous(domain: String, choices: [AuthChoice])

    /// Whether the state is the end of a run (the HUD fades by itself) rather than waiting for the user.
    var isTerminal: Bool {
        switch self {
        case .filled, .denied, .timedOut, .locked, .offline, .pageChanged, .failed, .unsupportedApp, .noPage: return true
        default: return false
        }
    }
}

@MainActor @Observable
final class AuthHUDModel {
    var state: AuthHUDState
    var actions = AuthHUDActions()
    init(state: AuthHUDState = .asking) { self.state = state }
}

@MainActor
protocol AuthHUDPresenting: AnyObject {
    func present(_ model: AuthHUDModel)
    func dismiss()
}

// MARK: Controller

private enum HUDChoice: Equatable {
    case proceed, cancel, startLink, pick(String), confirm
}

@MainActor
final class AuthShortcutController {
    struct Hooks {
        var automationExplained: () -> Bool
        var setAutomationExplained: () -> Void
    }

    let model = AuthHUDModel()
    private let broker: AuthBroker
    private let browsers: FrontBrowserProviding
    private let typer: CodeTyping
    private let accessibility: AccessibilityChecking
    private let hud: AuthHUDPresenting
    var hooks: Hooks
    private let psl: PublicSuffixList
    private let openAccessibility: () -> Void
    private let openAutomation: () -> Void
    private let finalDisplay: TimeInterval

    private var run: Task<Void, Never>?
    private var waiter: CheckedContinuation<HUDChoice, Never>?
    private var dismissWork: DispatchWorkItem?

    var isRunning: Bool { run != nil }

    init(broker: AuthBroker, browsers: FrontBrowserProviding, typer: CodeTyping, accessibility: AccessibilityChecking,
         hud: AuthHUDPresenting, hooks: Hooks = Hooks(automationExplained: { false }, setAutomationExplained: {}), psl: PublicSuffixList = .shared, finalDisplay: TimeInterval = 2.2,
         openAccessibility: @escaping () -> Void, openAutomation: @escaping () -> Void) {
        self.broker = broker; self.browsers = browsers; self.typer = typer; self.accessibility = accessibility
        self.hud = hud; self.hooks = hooks; self.psl = psl; self.finalDisplay = finalDisplay
        self.openAccessibility = openAccessibility; self.openAutomation = openAutomation
        model.actions = AuthHUDActions(
            cancel: { [weak self] in self?.userChose(.cancel) },
            proceed: { [weak self] in self?.userChose(.proceed) },
            startLink: { [weak self] in self?.userChose(.startLink) },
            pick: { [weak self] id in self?.userChose(.pick(id)) },
            confirmLookalike: { [weak self] in self?.userChose(.confirm) },
            openAccessibility: { [weak self] in self?.openAccessibility(); self?.userChose(.cancel) },
            openAutomation: { [weak self] in self?.openAutomation(); self?.userChose(.cancel) })
    }

    /// The shortcut. Pressing it while a run is going cancels that run.
    func trigger() {
        if run != nil { cancel(); return }
        dismissWork?.cancel()
        run = Task { [weak self] in
            await self?.flow()
            self?.run = nil
        }
    }

    func cancel() {
        run?.cancel()
        userChose(.cancel)
        hud.dismiss()
    }

    private func userChose(_ c: HUDChoice) {
        // A terminal HUD has no run behind it: its Cancel button just closes it.
        if run == nil { hud.dismiss(); return }
        let w = waiter; waiter = nil
        if c == .cancel, w == nil { run?.cancel(); hud.dismiss(); return }
        w?.resume(returning: c)
    }

    private func choice() async -> HUDChoice {
        await withCheckedContinuation { (c: CheckedContinuation<HUDChoice, Never>) in
            if Task.isCancelled { c.resume(returning: .cancel); return }
            waiter = c
        }
    }

    private func show(_ s: AuthHUDState) {
        model.state = s
        hud.present(model)
    }

    /// Shows an ending state, then fades out by itself.
    private func finish(_ s: AuthHUDState, seconds: TimeInterval? = nil) {
        show(s)
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hud.dismiss() } }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (seconds ?? finalDisplay), execute: work)
    }

    // MARK: The run

    private func flow() async {
        let app = browsers.frontmost()
        guard case let .browser(browser) = app else {
            if case let .other(name) = app { finish(.unsupportedApp(name), seconds: 3.5) }
            return
        }
        if !hooks.automationExplained() {
            show(.explainAutomation(browser: browser.name))
            guard await choice() == .proceed else { hud.dismiss(); return }
            hooks.setAutomationExplained()
        }
        show(.asking)
        let first = await browsers.currentURL(of: browser)
        if Task.isCancelled { hud.dismiss(); return }
        guard case let .url(url) = first else {
            if first == .automationDenied { show(.needsAutomation(browser: browser.name)); _ = await choice(); hud.dismiss() }
            else { finish(.noPage, seconds: 3.5) }
            return
        }
        guard let site = AuthSite(url: url, psl: psl) else { finish(.noPage, seconds: 3.5); return }
        guard accessibility.isTrusted else { show(.needsAccessibility); _ = await choice(); hud.dismiss(); return }

        var entryId: String?
        while !Task.isCancelled {
            show(.waiting(domain: site.domain))
            let outcome = await broker.requestCode(AuthCodeRequest(domain: site.domain, host: site.host, entryId: entryId,
                                                                   client: "\(browser.name) via shortcut"))
            if Task.isCancelled { hud.dismiss(); return }
            switch outcome {
            case let .code(code, _, _):
                // The approval took a while: the page must still be this site in this browser, or nothing is typed.
                guard case let .browser(now) = browsers.frontmost(), now == browser,
                      case let .url(u2) = await browsers.currentURL(of: browser), AuthSite(url: u2, psl: psl)?.domain == site.domain
                else { finish(.pageChanged, seconds: 3.5); return }
                await typer.type(code)
                finish(.filled(domain: site.domain))
                return
            case let .ambiguous(choices):
                show(.ambiguous(domain: site.domain, choices: choices))
                guard case let .pick(id) = await choice() else { hud.dismiss(); return }
                entryId = id
            case .noMatch:
                show(.noMatch(domain: site.domain))
                guard await choice() == .startLink else { hud.dismiss(); return }
                guard let id = await linkFlow(site) else { return }
                entryId = id
            case .denied: finish(.denied, seconds: 3); return
            case .timeout: finish(.timedOut, seconds: 3); return
            case .locked: finish(.locked, seconds: 4); return
            case .offline: finish(.offline, seconds: 3.5); return
            case .cancelled: hud.dismiss(); return
            case .failed: finish(.failed, seconds: 3); return
            }
        }
    }

    /// Picks an account for this site, with a lookalike warning that has to be confirmed. Returns the entry id once linked.
    private func linkFlow(_ site: AuthSite) async -> String? {
        show(.asking)
        guard let entries = await broker.fetchList() else {
            finish(broker.isConnected ? .failed : .offline, seconds: 3); return nil
        }
        show(.link(domain: site.domain, entries: entries))
        guard case let .pick(id) = await choice(), let entry = entries.first(where: { $0.id == id }) else { hud.dismiss(); return nil }
        if let l = LookalikeDetector.assess(host: site.host, known: KnownSite.from(entries), psl: psl) {
            show(.linkConfirm(domain: site.domain, entry: entry, lookalike: l))
            guard await choice() == .confirm else { hud.dismiss(); return nil }
        }
        guard broker.setDomain(entryId: entry.id, domain: site.domain) else { finish(.offline, seconds: 3); return nil }
        return entry.id
    }
}

// MARK: Stand-ins for fixtures and tests

@MainActor
final class NullFrontBrowser: FrontBrowserProviding {
    var app: FrontApp = .other(name: nil)
    var urls: [BrowserURLResult] = []
    private(set) var reads = 0
    func frontmost() -> FrontApp { app }
    func currentURL(of browser: FrontBrowser) async -> BrowserURLResult {
        defer { reads += 1 }
        return urls.isEmpty ? .unavailable : urls[min(reads, urls.count - 1)]
    }
}

@MainActor
final class NullTyper: CodeTyping {
    private(set) var typed: [String] = []
    func type(_ code: String) async { typed.append(code) }
}
