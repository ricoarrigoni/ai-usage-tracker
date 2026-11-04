import Foundation
import UsageCore
import UserNotifications

/// Delivers limit alerts. The delegate lets banners show even while the app's own panel is open.
final class AlertNotifier: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private var center: UNUserNotificationCenter { .current() }

    func start() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func send(_ alerts: [LimitAlert], now: Date = Date()) {
        for alert in alerts {
            send(id: alert.id, title: alert.title, body: alert.body(now: now))
        }
    }

    func send(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
