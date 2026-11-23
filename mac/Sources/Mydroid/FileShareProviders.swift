import AppKit
import QuickLookThumbnailing
import ImageIO
import UniformTypeIdentifiers
import MydroidCore

/// QuickLook thumbnails for `fs.thumb`. Only real previews are returned; for a file that has none the phone keeps its own icon.
final class QuickLookThumbnails: FileThumbnailProvider {
    func thumbnail(for url: URL, maxPixel: Int, completion: @escaping (Data?) -> Void) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: maxPixel, height: maxPixel), scale: 1,
                                                   representationTypes: [.thumbnail, .lowQualityThumbnail])
        request.iconMode = false
        let once = Once(completion)
        // A file that never finishes (a slow network volume, a broken generator) must not hold a phone request forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            QLThumbnailGenerator.shared.cancel(request)
            once.call(nil)
        }
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            once.call(rep.flatMap { Self.jpeg($0.cgImage) })
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let block: (Data?) -> Void
        init(_ block: @escaping (Data?) -> Void) { self.block = block }
        func call(_ d: Data?) {
            lock.lock(); let first = !done; done = true; lock.unlock()
            if first { block(d) }
        }
    }

    /// JPEG on a white background (transparent images would otherwise come out black).
    static func jpeg(_ image: CGImage) -> Data? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flat = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

/// Spotlight search and "recent files" for `fs.search` and `fs.recent`, limited to the shared folders. `NSMetadataQuery` needs the main
/// run loop, so everything here hops to the main queue.
final class SpotlightSearch: FileSearchProvider {
    private var active: [UUID: NSMetadataQuery] = [:]
    static let timeout: TimeInterval = 6

    func search(query: String, in roots: [URL], limit: Int, completion: @escaping ([URL]) -> Void) {
        let name = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, query)
        DispatchQueue.main.async { self.run(predicate: name, sort: nil, roots: roots, limit: limit, completion: completion) }
    }

    func recent(in roots: [URL], limit: Int, completion: @escaping ([URL]) -> Void) {
        let used = NSPredicate(format: "%K > %@", NSMetadataItemLastUsedDateKey, Date(timeIntervalSince1970: 0) as NSDate)
        let notFolder = NSPredicate(format: "%K != %@", NSMetadataItemContentTypeKey, "public.folder")
        let sort = NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)
        DispatchQueue.main.async {
            self.run(predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [used, notFolder]), sort: sort, roots: roots, limit: limit, completion: completion)
        }
    }

    @MainActor
    private func run(predicate: NSPredicate, sort: NSSortDescriptor?, roots: [URL], limit: Int, completion: @escaping ([URL]) -> Void) {
        let q = NSMetadataQuery()
        q.searchScopes = roots
        q.predicate = predicate
        if let sort { q.sortDescriptors = [sort] }
        let id = UUID()
        active[id] = q
        var token: NSObjectProtocol?
        var finished = false
        let finish: () -> Void = { [weak self, weak q] in
            guard !finished, let q else { return }
            finished = true
            q.disableUpdates()
            q.stop()
            if let token { NotificationCenter.default.removeObserver(token) }
            var urls: [URL] = []
            for i in 0..<min(q.resultCount, limit) {
                if let item = q.result(at: i) as? NSMetadataItem, let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                    urls.append(URL(fileURLWithPath: path))
                }
            }
            self?.active[id] = nil
            completion(urls)
        }
        token = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { _ in finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { finish() }
        if !q.start() { finish() }
    }
}
