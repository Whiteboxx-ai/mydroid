import Foundation
import Security

public protocol KeyValueStore: AnyObject, Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

/// Plain files under a directory. Used by the test server and tests; never touches the Keychain.
public final class FileKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let dir: URL
    private let lock = NSLock()
    public init(directory: URL) {
        dir = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    public func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: dir.appendingPathComponent(key))
    }
    public func set(_ data: Data?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        let url = dir.appendingPathComponent(key)
        if let data {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Generic-password items in the login Keychain.
public final class KeychainKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let service: String
    public init(service: String) { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func data(forKey key: String) -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public func set(_ data: Data?, forKey key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let data else { return }
        var q = query(key)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}

public final class UserDefaultsKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix: String
    public init(defaults: UserDefaults = .standard, prefix: String = "mydroid.") {
        self.defaults = defaults
        self.prefix = prefix
    }
    public func data(forKey key: String) -> Data? { defaults.data(forKey: prefix + key) }
    public func set(_ data: Data?, forKey key: String) { defaults.set(data, forKey: prefix + key) }
}

/// macId, LTK and phoneId (plus the phone's display name). The macId is generated once.
public final class Identity: @unchecked Sendable {
    private let store: KeyValueStore
    private let lock = NSLock()
    private var cachedMacId: String?

    public init(store: KeyValueStore) { self.store = store }

    public var macId: String {
        lock.lock(); defer { lock.unlock() }
        if let cachedMacId { return cachedMacId }
        if let d = store.data(forKey: "macId"), let s = String(data: d, encoding: .utf8), !s.isEmpty {
            cachedMacId = s
            return s
        }
        let id = UUID().uuidString.lowercased()
        store.set(Data(id.utf8), forKey: "macId")
        cachedMacId = id
        return id
    }

    public var ltk: Data? { store.data(forKey: "ltk") }
    public var phoneId: String? { store.data(forKey: "phoneId").flatMap { String(data: $0, encoding: .utf8) } }
    public var phoneName: String? { store.data(forKey: "phoneName").flatMap { String(data: $0, encoding: .utf8) } }
    public var isPaired: Bool { ltk != nil && phoneId != nil }

    public func savePairing(phoneId: String, ltk: Data, phoneName: String) {
        store.set(ltk, forKey: "ltk")
        store.set(Data(phoneId.utf8), forKey: "phoneId")
        store.set(Data(phoneName.utf8), forKey: "phoneName")
    }

    public func updatePhoneName(_ name: String) { store.set(Data(name.utf8), forKey: "phoneName") }

    public func clearPairing() {
        store.set(nil, forKey: "ltk")
        store.set(nil, forKey: "phoneId")
        store.set(nil, forKey: "phoneName")
    }
}

// MARK: Where the pairing secrets live

/// Whether this process is signed with an Apple-issued Team ID (Developer ID / App Store builds).
public enum CodeIdentity {
    public static var hasTeamID: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return false }
        return (d[kSecCodeInfoTeamIdentifier as String] as? String)?.isEmpty == false
    }
}

public enum SecretStorage {
    /// The store for pairing secrets.
    ///
    /// Team-signed builds use the login Keychain: their identity is stable across updates, so the user's
    /// "Always Allow" sticks. Locally built (ad-hoc signed) builds can't use it sensibly: macOS ties each
    /// item to that build's cdhash, so every rebuild asked for the login password once per item. Those
    /// builds keep the secrets in a 0600 file in a 0700 folder under Application Support instead.
    public static func make(service: String, supportDirectory: URL) -> KeyValueStore {
        if CodeIdentity.hasTeamID { return KeychainKeyValueStore(service: service) }
        let dir = supportDirectory.appendingPathComponent("secrets", isDirectory: true)
        let store = FileKeyValueStore(directory: dir)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        migrateFromKeychainSilently(service: service, keys: ["ltk", "macId", "phoneId", "phoneName"], into: store)
        return store
    }

    /// Copies Keychain items that macOS will hand over *without* asking. Never shows a prompt: if an item
    /// needs the user's password, it's skipped (the user re-pairs once instead).
    @discardableResult
    public static func migrateFromKeychainSilently(service: String, keys: [String], into store: KeyValueStore) -> Int {
        guard keys.contains(where: { store.data(forKey: $0) == nil }) else { return 0 }
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        var moved = 0
        for key in keys where store.data(forKey: key) == nil {
            var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
            q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
                store.set(d, forKey: key); moved += 1
            }
        }
        return moved
    }
}
