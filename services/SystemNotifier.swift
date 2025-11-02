import Foundation
import UserNotifications

final class SystemNotifier: NSObject {
    @MainActor static let shared = SystemNotifier()
    private var bootstrapped = false

    @MainActor func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    @MainActor func notify(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.2, repeats: false)
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: trigger)
        try? await center.add(request)
    }

    // Specialized helper: agent completed and awaits user follow-up.
    // Also posts an in-app notification to update list indicators.
    @MainActor func notifyAgentCompleted(sessionID: String, message: String) async {
        await notify(title: "CodMate", body: message)
        NotificationCenter.default.post(
            name: .codMateAgentCompleted,
            object: nil,
            userInfo: ["sessionID": sessionID, "message": message]
        )
    }
}

nonisolated extension SystemNotifier: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Call completion handler directly without actor hop to avoid sending non-Sendable closure
        completionHandler([.banner, .list, .sound])
    }
}

extension Notification.Name {
    static let codMateAgentCompleted = Notification.Name("CodMate.AgentCompleted")
    static let codMateStartEmbeddedNewProject = Notification.Name("CodMate.StartEmbeddedNewProject")
    static let codMateToggleSidebar = Notification.Name("CodMate.ToggleSidebar")
    static let codMateToggleList = Notification.Name("CodMate.ToggleList")
}
