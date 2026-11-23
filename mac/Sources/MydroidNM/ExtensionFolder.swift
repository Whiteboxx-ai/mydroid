import Foundation

/// The browser extension's stable home: `~/Library/Application Support/Mydroid/Browser Extension/`.
///
/// "Load unpacked" needs a folder that stays put, so the app copies the extension it carries out of its bundle into this one
/// at launch (and again when the bundled version is newer). Browsers load from here, never from the app bundle or Downloads.
public enum ExtensionFolder {
    public static let folderName = "Browser Extension"

    public static func stableURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Mydroid", isDirectory: true).appendingPathComponent(folderName, isDirectory: true)
    }

    public enum Outcome: Equatable, Sendable {
        /// First copy.
        case created
        /// Replaced by a newer bundled version (or the same version with different files).
        case updated
        /// Already up to date, or newer than the app's copy.
        case current
        /// The app carries no extension (a `swift run` build).
        case noSource
    }

    /// The manifest's `version`, or nil.
    public static func version(in dir: URL) -> String? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["version"] as? String
    }

    /// Compares dotted numbers ("0.2.0" > "0.1.9" > "0.1"). Missing parts count as 0.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Files that belong in the copy: everything except tests and Finder litter.
    static func files(in root: URL) -> [String] {
        let fm = FileManager.default
        guard let it = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        let base = root.standardizedFileURL.path
        for case let u as URL in it {
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count + 1))
            if rel == "test" || rel.hasPrefix("test/") { if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { it.skipDescendants() }; continue }
            if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out.append(rel) }
        }
        return out.sorted()
    }

    static func sameContents(_ a: URL, _ b: URL) -> Bool {
        let fa = files(in: a), fb = files(in: b)
        guard fa == fb else { return false }
        return fa.allSatisfy { FileManager.default.contentsEqual(atPath: a.appendingPathComponent($0).path, andPath: b.appendingPathComponent($0).path) }
    }

    /// Copies `bundled` into `stable` when `stable` is missing or older. The manifest is written last, so a browser that reloads
    /// halfway never sees a new manifest next to old scripts.
    @discardableResult
    public static func sync(bundled: URL?, stable: URL) throws -> Outcome {
        let fm = FileManager.default
        guard let bundled, fm.fileExists(atPath: bundled.appendingPathComponent("manifest.json").path) else { return .noSource }
        let existing = version(in: stable)
        var outcome = Outcome.created
        if let existing {
            let newVersion = version(in: bundled).map { compare($0, existing) == .orderedDescending } ?? false
            let sameVersion = version(in: bundled).map { compare($0, existing) == .orderedSame } ?? false
            if newVersion || (sameVersion && !sameContents(bundled, stable)) { outcome = .updated } else { return .current }
        }
        try fm.createDirectory(at: stable, withIntermediateDirectories: true)
        let list = files(in: bundled)
        for rel in list.sorted(by: { ($0 == "manifest.json" ? 1 : 0) < ($1 == "manifest.json" ? 1 : 0) }) {
            let from = bundled.appendingPathComponent(rel), to = stable.appendingPathComponent(rel)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = stable.appendingPathComponent(".mydroid-tmp")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: from, to: tmp)
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            try fm.moveItem(at: tmp, to: to)
        }
        for rel in files(in: stable) where !list.contains(rel) { try? fm.removeItem(at: stable.appendingPathComponent(rel)) }
        return outcome
    }
}
