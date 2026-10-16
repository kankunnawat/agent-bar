import AgentBarCore
import Foundation
import UserNotifications

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func deliver(_ events: [AlertEvent]) {
        let center = UNUserNotificationCenter.current()
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = .default
            center.add(UNNotificationRequest(
                identifier: "agentbar-\(event.accountID)-\(UUID().uuidString)",
                content: content, trigger: nil))
        }
    }
}
