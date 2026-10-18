import AppKit
import UserNotifications
import ZCCareCore

/// Posts what a refresh found new; clicking a notification opens the panel,
/// or the Care window for what Smart Care found.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Gets the notification's id.
    var onOpen: ((String) -> Void)?
    private var center: UNUserNotificationCenter { .current() }

    /// Whether macOS lets the notifications through; false when the user
    /// turned them off, or macOS refuses the app.
    func authorize() async -> Bool {
        center.delegate = self
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }

    /// A few alerts each, the rest summed up, so a big refresh is not a flood.
    func post(_ alerts: [Alert]) {
        let shown = alerts.count > 3 ? Array(alerts.prefix(2)) : alerts
        for a in shown { send(id: a.id, title: a.title, body: a.body) }
        if alerts.count > 3 {
            send(id: "more " + alerts.map(\.id).joined(), title: "\(alerts.count - 2) more need attention",
                 body: alerts.dropFirst(2).map(\.title).joined(separator: ", "))
        }
    }

    private func send(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = "zccare"
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        await MainActor.run { onOpen?(id) }
    }

    /// A menu bar app is often frontmost when it refreshes; show it anyway.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
