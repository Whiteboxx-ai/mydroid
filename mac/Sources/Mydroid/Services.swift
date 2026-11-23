import AppKit
import MydroidCore

/// macOS Services entry ("Send to Phone") for text, URLs and files. Declared as `NSServices` in Info.plist.
final class ServicesProvider: NSObject {
    static let shared = ServicesProvider()

    @objc func sendToPhone(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let payload = Self.payload(from: pboard) else {
            error.pointee = "Nothing to send." as NSString
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // Any web page can open a mydroid:// link, so a file send through the URL scheme
                // always asks first. Text and links are harmless to send and go straight through.
                if case let .files(urls) = payload {
                    guard Self.confirmFileSend(urls) else { return }
                }
                AppModel.shared.send(payload)
            }
        }
    }

    @MainActor
    private static func confirmFileSend(_ urls: [URL]) -> Bool {
        let phone = AppModel.shared.state.phone?.name ?? "your phone"
        let alert = NSAlert()
        alert.messageText = urls.count == 1 ? "Send \u{201C}\(urls[0].lastPathComponent)\u{201D} to \(phone)?"
                                            : "Send \(urls.count) files to \(phone)?"
        alert.informativeText = "Something asked Mydroid to send " + (urls.count == 1 ? "this file." : "these files.") + " Only continue if you started it."
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Files first, then a single URL, then text.
    static func payload(from pb: NSPasteboard) -> SendPayload? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        if let s = pb.string(forType: .URL) ?? pb.string(forType: .string) { return SendPayload.classify(text: s) }
        return nil
    }
}

/// Handles `mydroid://send?...` (for Shortcuts' "Open URL").
final class URLSchemeHandler: NSObject {
    static let shared = URLSchemeHandler()

    func register() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handle(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s),
              let payload = SendPayload.parse(schemeURL: url) else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.send(payload) } }
    }
}
