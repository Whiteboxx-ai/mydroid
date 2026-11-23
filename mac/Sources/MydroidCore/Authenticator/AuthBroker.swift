import Foundation

// PROTOCOL.md 14.2. The Mac never sees secrets: only metadata (`auth.list`) and one current code per approved request.
// Nothing here logs. Issuers, accounts and codes stay out of descriptions on purpose.

/// An authenticator entry as the phone lists it. Never a secret.
public struct AuthEntry: Equatable, Sendable {
    public var id: String
    public var issuer: String
    public var account: String
    public var domains: [String]
    public var digits: Int
    public init(id: String, issuer: String, account: String, domains: [String] = [], digits: Int = 6) {
        self.id = id; self.issuer = issuer; self.account = account; self.domains = domains; self.digits = digits
    }
}

/// One of the phone's candidates in an `ambiguous` reply.
public struct AuthChoice: Equatable, Sendable {
    public var id: String
    public var issuer: String
    public var account: String
    public init(id: String, issuer: String, account: String) { self.id = id; self.issuer = issuer; self.account = account }
}

/// What a code request came to. `offline`, `cancelled` and `timeout` can come from this side; the rest are the phone's `error` values.
public enum AuthOutcome: Equatable, Sendable, CustomStringConvertible {
    case code(String, validFor: Int, entryId: String?)
    case denied, timeout, noMatch, locked
    case ambiguous([AuthChoice])
    /// No phone connection (or it dropped while waiting).
    case offline
    case cancelled
    /// The phone's reply could not be understood.
    case failed

    /// Never includes the code.
    public var description: String {
        switch self {
        case .code: return "code"
        case .denied: return "denied"
        case .timeout: return "timeout"
        case .noMatch: return "no_match"
        case .locked: return "locked"
        case .ambiguous(let c): return "ambiguous(\(c.count))"
        case .offline: return "offline"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }

    /// The wire word for the socket protocol and the extension.
    public var errorName: String? {
        switch self {
        case .code: return nil
        case .denied: return "denied"
        case .timeout: return "timeout"
        case .noMatch: return "no_match"
        case .locked: return "locked"
        case .ambiguous: return "ambiguous"
        case .offline: return "offline"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }
}

/// What a camera import came to (PROTOCOL.md 14.4). Never carries a URI.
public enum AuthImportOutcome: Equatable, Sendable, CustomStringConvertible {
    case added(added: Int, skipped: Int)
    /// The phone's own errors.
    case cancelled, locked, invalid
    /// From this side: no phone connection, no answer in time, or a reply that could not be understood.
    case offline, timeout, failed

    public var description: String {
        switch self {
        case .added(let a, let s): return "added(\(a), skipped \(s))"
        case .cancelled: return "cancelled"
        case .locked: return "locked"
        case .invalid: return "invalid"
        case .offline: return "offline"
        case .timeout: return "timeout"
        case .failed: return "failed"
        }
    }
}

/// What the import window needs from the broker. A fake in tests.
public protocol AuthImporting: AnyObject, Sendable {
    /// Sends the codes to the phone and waits for its answer. The caller keeps no copy.
    func importAccounts(uris: [String]) async -> AuthImportOutcome
}

public struct AuthCodeRequest: Equatable, Sendable {
    /// The eTLD+1 (or the host itself for `localhost` and IP addresses).
    public var domain: String
    /// The full host the page is on.
    public var host: String
    public var account: String?
    public var entryId: String?
    /// For the phone's approval text, for example "Chrome" or "Safari via shortcut".
    public var client: String
    public init(domain: String, host: String, account: String? = nil, entryId: String? = nil, client: String) {
        self.domain = domain; self.host = host; self.account = account; self.entryId = entryId; self.client = client
    }
}

// MARK: Codec

public enum AuthCodec {
    public static func listGet(req: String) -> Message { Message("auth.list.get", ["req": req]) }

    public static func codeGet(req: String, _ r: AuthCodeRequest) -> Message {
        var f: [String: Any] = ["req": req, "domain": r.domain, "host": r.host, "client": r.client]
        if let a = r.account, !a.isEmpty { f["account"] = a }
        if let e = r.entryId, !e.isEmpty { f["entryId"] = e }
        return Message("auth.code.get", f)
    }

    public static func domainSet(entryId: String, domain: String) -> Message {
        Message("auth.domain.set", ["entryId": entryId, "domain": domain])
    }

    /// `req` is a string on the wire; a number is tolerated.
    public static func req(_ m: Message) -> String? {
        if let s = m.string("req"), !s.isEmpty { return s }
        if let n = m.int("req") { return String(n) }
        return nil
    }

    /// `uris` are the `otpauth://` and `otpauth-migration://` strings read from the QR codes.
    public static func importMessage(req: String, uris: [String]) -> Message {
        Message("auth.import", ["req": req, "uris": uris])
    }

    public static func decodeImport(_ m: Message) -> AuthImportOutcome {
        if m.bool("ok") == true {
            return .added(added: Int(m.int("added") ?? 0), skipped: Int(m.int("skipped") ?? 0))
        }
        switch m.string("error") {
        case "cancelled": return .cancelled
        case "locked": return .locked
        case "invalid": return .invalid
        default: return .failed
        }
    }

    public static func decodeList(_ m: Message) -> [AuthEntry] {
        (m.array("items") ?? []).compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            let digits = (d["digits"] as? NSNumber)?.intValue ?? 6
            return AuthEntry(id: id, issuer: d["issuer"] as? String ?? "", account: d["account"] as? String ?? "",
                             domains: (d["domains"] as? [String]) ?? [], digits: digits)
        }
    }

    public static func decodeOutcome(_ m: Message) -> AuthOutcome {
        if m.bool("ok") == true {
            guard let code = m.string("code"), !code.isEmpty else { return .failed }
            return .code(code, validFor: Int(m.int("validFor") ?? 30), entryId: m.string("entryId"))
        }
        switch m.string("error") {
        case "denied": return .denied
        case "timeout": return .timeout
        case "no_match": return .noMatch
        case "locked": return .locked
        case "ambiguous":
            let choices = (m.array("choices") ?? []).compactMap { d -> AuthChoice? in
                guard let id = d["id"] as? String else { return nil }
                return AuthChoice(id: id, issuer: d["issuer"] as? String ?? "", account: d["account"] as? String ?? "")
            }
            return .ambiguous(choices)
        default: return .failed
        }
    }
}

// MARK: Broker

/// Where the broker's messages go (the Hub, or a fake).
public protocol AuthTransport: AnyObject {
    func sendAuth(_ m: Message)
}

/// Sends `auth.code.get` and awaits the phone's `auth.code`, and the same for `auth.list.get` (kept in memory only).
/// Safe to call from any thread. A request ends exactly once: reply, timeout, cancellation or the connection dropping.
public final class AuthBroker: @unchecked Sendable, AuthImporting {
    /// The phone's own approval times out at 30 s, so wait a little longer than that.
    public static let defaultCodeTimeout: TimeInterval = 35
    public static let defaultListTimeout: TimeInterval = 10
    /// A person has to read the list on the phone and tap Add (and unlock it first), so this is generous.
    public static let defaultImportTimeout: TimeInterval = 120

    public let codeTimeout: TimeInterval
    public let listTimeout: TimeInterval
    public let importTimeout: TimeInterval
    private weak var transport: AuthTransport?
    private let lock = NSLock()
    private var connected = false
    private var codeWaiters: [String: CheckedContinuation<AuthOutcome, Never>] = [:]
    private var listWaiters: [String: CheckedContinuation<[AuthEntry]?, Never>] = [:]
    private var importWaiters: [String: CheckedContinuation<AuthImportOutcome, Never>] = [:]
    private var entries: [AuthEntry] = []
    private var counter = 0

    public init(transport: AuthTransport?, codeTimeout: TimeInterval = AuthBroker.defaultCodeTimeout,
                listTimeout: TimeInterval = AuthBroker.defaultListTimeout,
                importTimeout: TimeInterval = AuthBroker.defaultImportTimeout) {
        self.transport = transport; self.codeTimeout = codeTimeout; self.listTimeout = listTimeout; self.importTimeout = importTimeout
    }

    public func setTransport(_ t: AuthTransport?) { lock.lock(); transport = t; lock.unlock() }

    public var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connected }

    /// The last list the phone sent. Memory only; cleared when the phone goes away.
    public var cachedEntries: [AuthEntry] { lock.lock(); defer { lock.unlock() }; return entries }

    /// The Hub calls this when the phone session starts and ends. Ending fails everything still waiting.
    public func setConnected(_ up: Bool) {
        lock.lock()
        connected = up
        var codes: [CheckedContinuation<AuthOutcome, Never>] = []
        var lists: [CheckedContinuation<[AuthEntry]?, Never>] = []
        var imports: [CheckedContinuation<AuthImportOutcome, Never>] = []
        if !up {
            codes = Array(codeWaiters.values); codeWaiters.removeAll()
            lists = Array(listWaiters.values); listWaiters.removeAll()
            imports = Array(importWaiters.values); importWaiters.removeAll()
            entries = []
        }
        lock.unlock()
        for c in codes { c.resume(returning: .offline) }
        for c in lists { c.resume(returning: nil) }
        for c in imports { c.resume(returning: .offline) }
    }

    private func newReq() -> String {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return "a\(counter)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private func send(_ m: Message) { lock.lock(); let t = transport; lock.unlock(); t?.sendAuth(m) }

    // MARK: Code

    public func requestCode(_ r: AuthCodeRequest) async -> AuthOutcome {
        guard isConnected else { return .offline }
        let req = newReq()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<AuthOutcome, Never>) in
                lock.lock()
                if !connected { lock.unlock(); c.resume(returning: .offline); return }
                codeWaiters[req] = c
                lock.unlock()
                if Task.isCancelled { finishCode(req, .cancelled); return }       // cancelled before the waiter existed
                DispatchQueue.global().asyncAfter(deadline: .now() + codeTimeout) { [weak self] in self?.finishCode(req, .timeout) }
                send(AuthCodec.codeGet(req: req, r))
            }
        } onCancel: { [weak self] in self?.finishCode(req, .cancelled) }
    }

    private func finishCode(_ req: String, _ outcome: AuthOutcome) {
        lock.lock(); let c = codeWaiters.removeValue(forKey: req); lock.unlock()
        c?.resume(returning: outcome)
    }

    // MARK: List

    /// The phone's list, or nil when it can't be had (offline, timed out).
    public func fetchList() async -> [AuthEntry]? {
        guard isConnected else { return nil }
        let req = newReq()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<[AuthEntry]?, Never>) in
                lock.lock()
                if !connected { lock.unlock(); c.resume(returning: nil); return }
                listWaiters[req] = c
                lock.unlock()
                if Task.isCancelled { finishList(req, nil); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + listTimeout) { [weak self] in self?.finishList(req, nil) }
                send(AuthCodec.listGet(req: req))
            }
        } onCancel: { [weak self] in self?.finishList(req, nil) }
    }

    private func finishList(_ req: String, _ list: [AuthEntry]?) {
        lock.lock(); let c = listWaiters.removeValue(forKey: req); lock.unlock()
        c?.resume(returning: list)
    }

    // MARK: Camera import (PROTOCOL.md 14.4)

    /// Sends `auth.import` and waits for `auth.import.result`. The strings are only in the outgoing message; nothing here keeps them
    /// or logs them, and the waiter holds a request id and nothing else.
    public func importAccounts(uris: [String]) async -> AuthImportOutcome {
        guard isConnected, !uris.isEmpty else { return .offline }
        let req = newReq()
        let message = AuthCodec.importMessage(req: req, uris: uris)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<AuthImportOutcome, Never>) in
                lock.lock()
                if !connected { lock.unlock(); c.resume(returning: .offline); return }
                importWaiters[req] = c
                lock.unlock()
                if Task.isCancelled { finishImport(req, .cancelled); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + importTimeout) { [weak self] in self?.finishImport(req, .timeout) }
                send(message)
            }
        } onCancel: { [weak self] in self?.finishImport(req, .cancelled) }
    }

    private func finishImport(_ req: String, _ outcome: AuthImportOutcome) {
        lock.lock(); let c = importWaiters.removeValue(forKey: req); lock.unlock()
        c?.resume(returning: outcome)
    }

    // MARK: Teaching a domain

    /// The user linked this site to the entry (`auth.domain.set`). Fire and forget; the phone persists it. Also updates the cached list.
    @discardableResult
    public func setDomain(entryId: String, domain: String) -> Bool {
        guard isConnected else { return false }
        lock.lock()
        if let i = entries.firstIndex(where: { $0.id == entryId }), !entries[i].domains.contains(domain) { entries[i].domains.append(domain) }
        lock.unlock()
        send(AuthCodec.domainSet(entryId: entryId, domain: domain))
        return true
    }

    // MARK: Inbound

    /// Feed `auth.code` and `auth.list` from the phone. Other types are ignored. Replies with an unknown `req` (late, or not ours) are dropped.
    public func handle(_ m: Message) {
        switch m.type {
        case "auth.code":
            guard let req = AuthCodec.req(m) else { return }
            finishCode(req, AuthCodec.decodeOutcome(m))
        case "auth.list":
            guard let req = AuthCodec.req(m) else { return }
            let items = AuthCodec.decodeList(m)
            lock.lock(); entries = items; lock.unlock()
            finishList(req, items)
        case "auth.import.result":
            guard let req = AuthCodec.req(m) else { return }
            finishImport(req, AuthCodec.decodeImport(m))
        default: break
        }
    }
}
