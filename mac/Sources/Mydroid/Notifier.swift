import SwiftUI
import AppKit
import UserNotifications
import MydroidCore

/// Phone notifications on the Mac. Prefers `UNUserNotificationCenter` (with Reply and Dismiss
/// actions). When that isn't available, for example an ad-hoc signed build that macOS won't
/// authorize, it falls back to its own floating banner with inline reply.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let replyCategory = "MYDROID_REPLYABLE"
    static let plainCategory = "MYDROID_PLAIN"
    static let otpCategory = "MYDROID_OTP"
    static let copyAction = "MYDROID_COPY_CODE"
    static let replyAction = "MYDROID_REPLY"
    static let dismissAction = "MYDROID_DISMISS"
    static let muteAction = "MYDROID_MUTE"
    static let openLinkAction = "MYDROID_OPEN_LINK"
    static let linkCategory = "MYDROID_LINK"
    static let qsRequestCategory = "MYDROID_QS_REQUEST"
    static let qsSavedCategory = "MYDROID_QS_SAVED"
    static let qsAcceptAction = "MYDROID_QS_ACCEPT"
    static let qsDeclineAction = "MYDROID_QS_DECLINE"
    static let qsRevealAction = "MYDROID_QS_REVEAL"

    weak var model: AppModel?
    private(set) var useSystem = false
    private var center: UNUserNotificationCenter?
    let banners = BannerCenter()

    func prepare() {
        banners.model = model
        // UNUserNotificationCenter traps when the process isn't a bundled app (e.g. `swift run`).
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return }
        let c = UNUserNotificationCenter.current()
        center = c
        c.delegate = self
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let dismiss = UNNotificationAction(identifier: Self.dismissAction, title: "Dismiss", options: [])
        let mute = UNNotificationAction(identifier: Self.muteAction, title: "Mute app", options: [])
        c.setNotificationCategories([
            UNNotificationCategory(identifier: Self.linkCategory,
                                   actions: [UNNotificationAction(identifier: Self.openLinkAction, title: "Open", options: [.foreground])],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.qsRequestCategory,
                                   actions: [UNNotificationAction(identifier: Self.qsAcceptAction, title: "Accept", options: []),
                                             UNNotificationAction(identifier: Self.qsDeclineAction, title: "Decline", options: [.destructive])],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.qsSavedCategory,
                                   actions: [UNNotificationAction(identifier: Self.qsRevealAction, title: "Show in Finder", options: [])],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.replyCategory, actions: [reply, dismiss, mute], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.otpCategory,
                                   actions: [UNNotificationAction(identifier: Self.copyAction, title: "Copy code", options: []), dismiss],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.plainCategory, actions: [dismiss, mute], intentIdentifiers: [], options: []),
        ])
        Task {
            let s = await c.notificationSettings()
            useSystem = (s.authorizationStatus == .authorized || s.authorizationStatus == .provisional)
            if s.authorizationStatus == .notDetermined, model?.state.settings.notifications == true { await requestAuthorization() }
        }
    }

    func requestAuthorization() async {
        guard let c = center else { return }
        let granted = (try? await c.requestAuthorization(options: [.alert, .sound])) ?? false
        useSystem = granted
    }

    func show(_ n: PhoneNotification, autoCopied: Bool = false) {
        guard useSystem, let center else { banners.show(n, autoCopied: autoCopied); return }
        let content = UNMutableNotificationContent()
        content.sound = nil
        content.userInfo = ["key": n.key, "pkg": n.pkg]
        if let otp = n.otp, n.hasActiveCode() {
            // Lead with the code.
            content.title = autoCopied ? "Code copied" : otp.grouped
            content.subtitle = autoCopied ? otp.grouped : codeSourceLine(n)
            content.body = autoCopied ? codeSourceLine(n) : "Verification code"
            content.categoryIdentifier = autoCopied ? Self.plainCategory : Self.otpCategory
            content.threadIdentifier = "otp"
        } else if let c = n.effectiveConversation {
            content.title = c.title.isEmpty ? n.displayApp : c.title
            content.subtitle = "via \(n.displayApp)"
            if let last = c.last {
                content.body = (c.isGroup && !last.isMine && !last.sender.isEmpty) ? "\(last.sender): \(last.text)" : last.text
            }
            content.categoryIdentifier = n.canReply ? Self.replyCategory : Self.plainCategory
            content.threadIdentifier = "msg:" + n.key
            Self.attach(c.avatar, to: content)
        } else {
            content.title = n.title.isEmpty ? n.displayApp : n.title
            content.subtitle = n.title.isEmpty ? "" : n.displayApp
            content.body = n.text
            content.categoryIdentifier = n.canReply ? Self.replyCategory : Self.plainCategory
            content.threadIdentifier = n.pkg.isEmpty ? n.displayApp : n.pkg
            Self.attach(n.icon, to: content)
        }
        let req = UNNotificationRequest(identifier: n.key, content: content, trigger: nil)
        center.add(req) { [weak self] error in
            if error != nil {
                // The system refused (not authorized after all). Use our own banner from now on.
                Task { @MainActor in self?.useSystem = false; self?.banners.show(n, autoCopied: autoCopied) }
            }
        }
    }

    /// A link from the phone, with an Open button.
    func showLink(_ url: URL, from phone: String) {
        guard useSystem, let center else { banners.showLink(url, from: phone); return }
        let content = UNMutableNotificationContent()
        content.title = "Link from \(phone)"
        content.body = url.absoluteString
        content.categoryIdentifier = Self.linkCategory
        content.userInfo = ["url": url.absoluteString]
        center.add(UNNotificationRequest(identifier: "link:" + UUID().uuidString, content: content, trigger: nil)) { [weak self] error in
            if error != nil { Task { @MainActor in self?.useSystem = false; self?.banners.showLink(url, from: phone) } }
        }
    }

    // MARK: Quick Share

    /// A device other than your phone wants to send something: Accept or Decline, with the PIN to check.
    func showQuickShareRequest(_ r: QuickShareIncoming) {
        guard useSystem, let center else { banners.showQuickShareRequest(r); return }
        let content = UNMutableNotificationContent()
        content.title = "\(r.sender) wants to share"
        content.subtitle = r.summary
        content.body = "PIN \(r.pin) \u{00B7} should match on \(r.sender)"
        content.categoryIdentifier = Self.qsRequestCategory
        content.userInfo = ["qsId": r.id]
        center.add(UNNotificationRequest(identifier: BannerCenter.quickShareKey(r.id), content: content, trigger: nil)) { [weak self] error in
            if error != nil { Task { @MainActor in self?.useSystem = false; self?.banners.showQuickShareRequest(r) } }
        }
    }

    /// The request is over (answered, timed out or cancelled): take its banner or notification away.
    func retractQuickShare(id: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [BannerCenter.quickShareKey(id)])
        banners.close(key: BannerCenter.quickShareKey(id))
    }

    /// Text from Quick Share is now on the clipboard.
    func showCopied(from: String, preview: String) {
        guard useSystem, let center else { banners.showCopied(from: from, preview: preview); return }
        let content = UNMutableNotificationContent()
        content.title = "Copied from \(from)"
        content.body = preview
        center.add(UNNotificationRequest(identifier: "copied:" + UUID().uuidString, content: content, trigger: nil)) { [weak self] error in
            if error != nil { Task { @MainActor in self?.useSystem = false; self?.banners.showCopied(from: from, preview: preview) } }
        }
    }

    func showSaved(_ d: QuickShareDone) {
        guard useSystem, let center else { banners.showSaved(d); return }
        let folder = d.files.first?.url.deletingLastPathComponent().lastPathComponent ?? "Downloads"
        let content = UNMutableNotificationContent()
        content.title = d.files.count == 1 ? "Saved to \(folder)" : "Saved \(d.files.count) files to \(folder)"
        content.body = d.files.count == 1 ? "\(d.files[0].name) from \(d.sender)" : "From \(d.sender)"
        content.categoryIdentifier = Self.qsSavedCategory
        content.userInfo = ["paths": d.files.map(\.url.path)]
        center.add(UNNotificationRequest(identifier: "saved:" + d.id, content: content, trigger: nil)) { [weak self] error in
            if error != nil { Task { @MainActor in self?.useSystem = false; self?.banners.showSaved(d) } }
        }
    }

    func showLowBattery(title: String, detail: String) {
        guard useSystem, let center else { banners.showLowBattery(title: title, detail: detail); return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = detail
        center.add(UNNotificationRequest(identifier: "mydroid.battery", content: content, trigger: nil)) { [weak self] error in
            if error != nil { Task { @MainActor in self?.useSystem = false; self?.banners.showLowBattery(title: title, detail: detail) } }
        }
    }

    private static func attach(_ data: Data?, to content: UNMutableNotificationContent) {
        guard let data, !data.isEmpty else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mydroid-\(UUID().uuidString).png")
        guard (try? data.write(to: url)) != nil else { return }
        if let a = try? UNNotificationAttachment(identifier: "img", url: url, options: nil) { content.attachments = [a] }
    }

    func retract(key: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [key])
        banners.close(key: key)
    }

    func retractAll() {
        center?.removeAllDeliveredNotifications()
        banners.closeAll()
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let key = response.notification.request.content.userInfo["key"] as? String
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let info = response.notification.request.content.userInfo
        let linkURL = (info["url"] as? String).flatMap(LinkPolicy.parse)
        let pkg = info["pkg"] as? String
        let qsId = info["qsId"] as? String
        let savedPaths = info["paths"] as? [String]
        Task { @MainActor in
            if let qsId {
                if action == Self.qsAcceptAction { self.model?.quickShareRespond(id: qsId, accept: true) }
                else if action == Self.qsDeclineAction || action == UNNotificationDismissActionIdentifier { self.model?.quickShareRespond(id: qsId, accept: false) }
            }
            if let savedPaths, action == Self.qsRevealAction || action == UNNotificationDefaultActionIdentifier {
                NSWorkspace.shared.activateFileViewerSelecting(savedPaths.map { URL(fileURLWithPath: $0) })
            }
            if let linkURL, action == Self.openLinkAction || action == UNNotificationDefaultActionIdentifier {
                NSWorkspace.shared.open(linkURL)
            }
            // A click on a phone notification (not a link, Quick Share or battery one) does that app's default.
            if action == UNNotificationDefaultActionIdentifier, let key, linkURL == nil, qsId == nil, savedPaths == nil {
                self.model?.openNotification(key: key)
            }
            if action == Self.muteAction, let pkg, !pkg.isEmpty { self.model?.setMuted(pkg, true) }
            if let key, let model = self.model {
                if action == Self.replyAction, let text, !text.isEmpty {
                    model.hub.reply(key: key, text: text)
                } else if action == Self.copyAction {
                    if let n = model.state.notifications.items.first(where: { $0.key == key }) { model.copyCode(n) }
                } else if action == Self.dismissAction || action == UNNotificationDismissActionIdentifier {
                    model.hub.dismiss(key: key)
                }
            }
            completionHandler()
        }
    }
}
