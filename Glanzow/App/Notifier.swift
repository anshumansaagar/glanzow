import AppKit
import UserNotifications
import GlanzowKit

/// One-time user notifications for the §7 edge cases and the FR-LRN-03 drift alert.
@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var sent: Set<String> = []
    /// "Exclude App" tapped on a video-call suggestion.
    var onExclude: ((String) -> Void)?

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: "callApp", actions: [UNNotificationAction(identifier: "exclude", title: "Exclude App")],
            intentIdentifiers: [])])
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts at most once per `id` until `forget(id)`.
    func once(_ id: String, title: String, body: String, category: String? = nil, userInfo: [String: String] = [:]) {
        guard sent.insert(id).inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = userInfo
        if let category { content.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func forget(_ id: String) { sent.remove(id) }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == "exclude",
              let bundle = response.notification.request.content.userInfo["bundleID"] as? String else { return }
        await MainActor.run { onExclude?(bundle) }
    }
}
