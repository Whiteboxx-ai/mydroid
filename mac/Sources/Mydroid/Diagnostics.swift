import AppKit

/// Temporary UI diagnostics: where clicks land and which sidebar section gets selected.
/// Records only window kind, key/active state, click position and section names. Never any content.
/// Log: ~/Library/Logs/Mydroid/ui-diagnostics.log (capped at 1 MB).
@MainActor
enum UIDiagnostics {
    private static var monitor: Any?
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mydroid", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ui-diagnostics.log")
    }()

    static func start() {
        guard monitor == nil else { return }
        log("start pid=\(ProcessInfo.processInfo.processIdentifier) policy=\(NSApp.activationPolicy().rawValue)")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
            let w = e.window
            let kind = w.map { "\(type(of: $0))#\($0.windowNumber) '\($0.identifier?.rawValue ?? "")'" } ?? "none"
            let hit = w?.contentView?.hitTest(e.locationInWindow).map { String(describing: type(of: $0)) } ?? "-"
            log("\(e.type == .leftMouseDown ? "down" : "up") win=\(kind) key=\(w?.isKeyWindow ?? false) main=\(w?.isMainWindow ?? false) "
                + "appActive=\(NSApp.isActive) loc=(\(Int(e.locationInWindow.x)),\(Int(e.locationInWindow.y))) hit=\(hit)")
            return e
        }
    }

    static func log(_ s: String) {
        let line = "\(Date().formatted(.iso8601)) \(s)\n"
        if let a = try? FileManager.default.attributesOfItem(atPath: url.path), (a[.size] as? Int ?? 0) > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
}
