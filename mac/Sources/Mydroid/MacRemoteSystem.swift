import AppKit
import MydroidCore

// The real macOS behind PROTOCOL.md section 16: NSWorkspace for apps and files, AppKit for icons and album art.

/// NSWorkspace, behind `AppWorkspace`.
final class AppKitWorkspace: AppWorkspace, @unchecked Sendable {
    func runningApps(limit: Int) -> [MacAppInfo] {
        let me = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != me && !$0.isTerminated }
            .sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }
        // The frontmost app first: it's the one people mean.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let ordered = apps.filter { $0.bundleIdentifier == front } + apps.filter { $0.bundleIdentifier != front }
        return ordered.prefix(limit).map { a in
            MacAppInfo(id: a.bundleIdentifier ?? "", name: a.localizedName ?? a.bundleIdentifier ?? "", icon: a.icon.flatMap { Self.png($0, pixels: 96) })
        }
    }

    func installedApps() -> [MacAppInfo] {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var seen = Set<String>()
        var out: [MacAppInfo] = []
        for d in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: d) else { continue }
            for n in names where n.hasSuffix(".app") {
                let url = URL(fileURLWithPath: d).appendingPathComponent(n)
                guard let b = Bundle(url: url), let id = b.bundleIdentifier, seen.insert(id).inserted, id != Bundle.main.bundleIdentifier else { continue }
                let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? String(n.dropLast(4))
                out.append(MacAppInfo(id: id, name: name))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.prefix(300).map { $0 }
    }

    func isRunning(_ bundleId: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty }
    func frontmostBundleId() -> String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    func launch(_ bundleId: String, completion: @escaping @Sendable (MacActionResult) -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return completion(.failure("not found")) }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
            completion(error == nil ? .success : .failure("Couldn't open it"))
        }
    }

    func open(_ url: URL, completion: @escaping @Sendable (MacActionResult) -> Void) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(url, configuration: cfg) { _, error in
            completion(error == nil ? .success : .failure("Couldn't open it"))
        }
    }

    func defaultAppId(for url: URL) -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// PNG at `pixels` square, drawn into a bitmap so the size is exact whatever the icon's representations are.
    static func png(_ image: NSImage, pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        return rep.representation(using: .png, properties: [:])
    }
}

/// Scales and encodes album art, and fetches the artwork Spotify points at.
final class AppKitArtwork: ArtworkEncoding, @unchecked Sendable {
    func jpeg(from data: Data, maxPixel: Int) -> Data? {
        guard let src = NSBitmapImageRep(data: data) ?? NSImage(data: data).flatMap({ $0.tiffRepresentation }).flatMap({ NSBitmapImageRep(data: $0) }) else { return nil }
        let w = CGFloat(src.pixelsWide), h = CGFloat(src.pixelsHigh)
        guard w > 0, h > 0 else { return nil }
        let k = min(1, CGFloat(maxPixel) / max(w, h))
        let tw = max(1, Int((w * k).rounded())), th = max(1, Int((h * k).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: tw, pixelsHigh: th, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: NSRect(x: 0, y: 0, width: tw, height: th))
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    func fetch(_ url: URL, completion: @escaping @Sendable (Data?) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            completion(ok && (data?.count ?? 0) < 4_000_000 ? data : nil)
        }.resume()
    }
}
