import SwiftUI
import MydroidCore

/// Recent calls (PROTOCOL.md 7.8) and dialing through the phone.
@MainActor @Observable
final class CallsModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", missed = "Missed"
        var id: String { rawValue }
    }

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let hub: Hub
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var noteTask: Task<Void, Never>?

    var records: [CallRecord] = []
    var loading = false
    var loaded = false
    var error: String?
    var filter: Filter = .all
    var number = ""
    /// "Calling on your phone", shown for a few seconds after a call was placed.
    var note: String?
    var selection: String?
    /// The phone answered `calls.page` with `error:"permission"`.
    var permissionDenied = false

    init(hub: Hub) { self.hub = hub }

    var visible: [CallRecord] { filter == .missed ? records.filter(\.isMissed) : records }

    func activate() {
        guard app?.state.link == .connected, !loading, !loaded || (lastFetch.map { Date().timeIntervalSince($0) > 60 } ?? true) else { return }
        refresh()
    }

    @ObservationIgnored private var lastFetch: Date?

    func refresh() {
        guard app?.state.link == .connected else { return }
        loading = true
        error = nil
        lastFetch = Date()
        hub.requestCalls(limit: 100)
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.loading else { return }
            self.loading = false
            if !self.loaded { self.error = "Your phone didn't answer." }
        }
    }

    func handle(_ e: HubEvent) {
        switch e {
        case let .callsPage(items, err):
            timeout?.cancel()
            loading = false
            if err == "permission" { permissionDenied = true; return }
            permissionDenied = false
            records = items.sorted { $0.date > $1.date }
            loaded = true; error = nil
        case .sessionClosed: loading = false
        case .sessionReady: if loaded { refresh() }
        default: break
        }
    }

    /// A call just ended on the phone: the list has a new entry.
    func callEnded() { if loaded { Task { [weak self] in try? await Task.sleep(for: .seconds(1.5)); self?.refresh() } } }

    /// What the phone accepts: digits with an optional leading +, and spaces, dots, dashes and brackets. No * or #
    /// (those can start USSD codes). Returns what is wrong, or nil.
    static func problem(with number: String) -> String? {
        let n = number.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return "Enter a number to call." }
        if n.contains(where: { $0 == "*" || $0 == "#" }) { return "Dial codes with * or # on your phone" }
        if !n.allSatisfy({ $0.isNumber || "+ ().-".contains($0) }) || n.dropFirst().contains("+") { return "That doesn't look like a phone number." }
        let digits = n.filter(\.isNumber).count
        return digits >= 3 && digits <= 20 ? nil : "That doesn't look like a phone number."
    }

    func dial(_ raw: String, name: String? = nil) {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if let why = Self.problem(with: n) { app?.flash(why); return }
        guard app?.state.link == .connected else { app?.flash("\(app?.phoneName ?? "Your phone") isn't connected"); return }
        app?.callAudio.noteDialFromMac()
        hub.dial(number: n)
        note = (app?.callAudio.tier == .full) ? "Calling \u{2014} you can talk on your Mac" : "Calling on your phone"
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { withAnimation(.spring(duration: 0.35)) { self?.note = nil } }
        }
        if loaded { callEnded() }
    }

    func press(_ key: String) { if number.count < 32 { number += key } }
    func backspace() { if !number.isEmpty { number.removeLast() } }
}
