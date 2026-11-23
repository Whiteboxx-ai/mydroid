import Foundation

/// What the bridge needs from the app: the phone link state and the per-site auto-fill list (kept in the app's preferences).
public protocol OTPBridgeHost: AnyObject {
    /// The phone is connected (so a code can be asked for).
    var phoneConnected: Bool { get }
    func autofillAllowed(domain: String) -> Bool
    func setAutofill(domain: String, enabled: Bool)
    /// The extension started in a browser and said hello. `browser` is the name it gives itself, `parent` the path of the program
    /// that started the helper (the browser's own executable), which tells Arc from Chrome.
    func extensionHello(browser: String?, parent: String?)
}

public extension OTPBridgeHost {
    func extensionHello(browser: String?, parent: String?) {}
}

/// Answers the browser extension's requests (relayed by `mydroid-nmhost` over the Unix socket). Requests and replies are plain JSON objects:
///
///     code     {host, account?, entryId?, client?}  ->  {ok, code?, validFor?, entryId?, error?, choices?, domain?}
///     list     {host?}                              ->  {ok, items:[{id,issuer,account,domains}], domain?, lookalike?}
///     link     {host, entryId, acknowledged?}       ->  {ok, domain} | {ok:false, error:"lookalike", lookalike}
///     status   {host?}                              ->  {ok, running, connected, autofill}
///     autofill {host, on}                           ->  {ok, domain}
///     hello    {browser?, parent?}                  ->  {ok, running, connected}   (the extension started; setup watches for it)
///
/// `id` in a request is echoed. Errors are `{ok:false, error}` with a short word, never any account detail.
public final class OTPBridge: @unchecked Sendable {
    public static let ops: Set<String> = ["code", "list", "link", "status", "autofill", "hello"]

    private let broker: AuthBroker
    private weak var host: OTPBridgeHost?
    private let psl: PublicSuffixList

    public init(broker: AuthBroker, host: OTPBridgeHost, psl: PublicSuffixList = .shared) {
        self.broker = broker; self.host = host; self.psl = psl
    }

    public func handle(_ request: [String: Any]) async -> [String: Any] {
        var reply = await route(request)
        if let id = request["id"] { reply["id"] = id }
        return reply
    }

    private func fail(_ e: String) -> [String: Any] { ["ok": false, "error": e] }

    /// A usable host from the request, and the domain to match on (the eTLD+1, or the host for `localhost` and IP addresses).
    private func target(_ r: [String: Any]) -> (host: String, domain: String)? {
        guard let raw = r["host"] as? String, let h = PublicSuffixList.normalizeHost(raw) else { return nil }
        return (h, psl.registrableDomain(of: h) ?? h)
    }

    private func route(_ r: [String: Any]) async -> [String: Any] {
        guard let op = r["op"] as? String, Self.ops.contains(op) else { return fail("bad_request") }
        switch op {
        case "status": return status(r)
        case "code": return await code(r)
        case "list": return await list(r)
        case "link": return await link(r)
        case "autofill": return autofill(r)
        case "hello":
            host?.extensionHello(browser: (r["browser"] as? String).map { String($0.prefix(40)) },
                                 parent: (r["parent"] as? String).map { String($0.prefix(512)) })
            return ["ok": true, "running": true, "connected": host?.phoneConnected ?? false]
        default: return fail("bad_request")
        }
    }

    private func status(_ r: [String: Any]) -> [String: Any] {
        var out: [String: Any] = ["ok": true, "running": true, "connected": host?.phoneConnected ?? false, "autofill": false]
        if let t = target(r) { out["autofill"] = host?.autofillAllowed(domain: t.domain) ?? false; out["domain"] = t.domain }
        return out
    }

    private func code(_ r: [String: Any]) async -> [String: Any] {
        guard let t = target(r) else { return fail("bad_request") }
        let account = (r["account"] as? String).map { String($0.prefix(254)) }
        let entryId = (r["entryId"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
        let client = (r["client"] as? String).map { String($0.prefix(40)) }.flatMap { $0.isEmpty ? nil : $0 } ?? "a browser"
        let req = AuthCodeRequest(domain: t.domain, host: t.host, account: account, entryId: entryId, client: client)
        return Self.reply(for: await broker.requestCode(req), domain: t.domain)
    }

    /// The socket and extension reply for an outcome.
    public static func reply(for outcome: AuthOutcome, domain: String? = nil) -> [String: Any] {
        var out: [String: Any]
        switch outcome {
        case let .code(code, validFor, entryId):
            out = ["ok": true, "code": code, "validFor": validFor]
            if let entryId { out["entryId"] = entryId }
            return out
        case let .ambiguous(choices):
            out = ["ok": false, "error": "ambiguous",
                   "choices": choices.map { ["id": $0.id, "issuer": $0.issuer, "account": $0.account] }]
        default:
            out = ["ok": false, "error": outcome.errorName ?? "failed"]
        }
        if let domain { out["domain"] = domain }
        return out
    }

    private func list(_ r: [String: Any]) async -> [String: Any] {
        guard let entries = await broker.fetchList() else { return fail(broker.isConnected ? "timeout" : "offline") }
        var out: [String: Any] = ["ok": true, "items": entries.map {
            ["id": $0.id, "issuer": $0.issuer, "account": $0.account, "domains": $0.domains] as [String: Any]
        }]
        if let t = target(r) {
            out["domain"] = t.domain
            if let l = LookalikeDetector.assess(host: t.host, known: KnownSite.from(entries), psl: psl) { out["lookalike"] = Self.json(l) }
        }
        return out
    }

    private func link(_ r: [String: Any]) async -> [String: Any] {
        guard let t = target(r), let entryId = r["entryId"] as? String, !entryId.isEmpty else { return fail("bad_request") }
        guard broker.isConnected else { return fail("offline") }
        if r["acknowledged"] as? Bool != true {
            // A lookalike has to be confirmed explicitly. If the list isn't known yet, fetch it so the check is real.
            var entries = broker.cachedEntries
            if entries.isEmpty { entries = await broker.fetchList() ?? [] }
            if let l = LookalikeDetector.assess(host: t.host, known: KnownSite.from(entries), psl: psl) {
                return ["ok": false, "error": "lookalike", "lookalike": Self.json(l), "domain": t.domain]
            }
        }
        guard broker.setDomain(entryId: entryId, domain: t.domain) else { return fail("offline") }
        return ["ok": true, "domain": t.domain]
    }

    private func autofill(_ r: [String: Any]) -> [String: Any] {
        guard let t = target(r), let on = r["on"] as? Bool, let host else { return fail("bad_request") }
        host.setAutofill(domain: t.domain, enabled: on)
        return ["ok": true, "domain": t.domain, "autofill": on]
    }

    static func json(_ l: Lookalike) -> [String: Any] {
        ["kind": l.kind.rawValue, "resembles": l.resembles, "issuer": l.issuer, "summary": l.summary]
    }
}
