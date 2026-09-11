import Foundation
import UserNotifications
import OSLog

/// One app-owned Apple notification boundary. Incoming OSC never requests permission.
final class NativeTerminalNotificationClient: NSObject, TerminalNotificationSending, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private let onOpen: @MainActor (TerminalNotificationContext) -> Void
    nonisolated private static let logger = Logger(subsystem: "app.vivy.VVTerm", category: "TerminalNotifications")

    init(center: UNUserNotificationCenter, onOpen: @escaping @MainActor (TerminalNotificationContext) -> Void) {
        self.center = center
        self.onOpen = onOpen
        super.init()
        center.delegate = self
    }

    func authorization() async -> TerminalNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        @unknown default: .unavailable
        }
    }

    func requestAuthorization() async -> TerminalNotificationAuthorization {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            return await authorization()
        } catch {
            Self.logger.error("Notification permission request failed: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
    }

    func post(_ content: TerminalNotificationContent, context: TerminalNotificationContext) {
        center.add(Self.request(content, context: context)) { error in
            if let error {
                Self.logger.error("Terminal notification delivery failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func request(
        _ content: TerminalNotificationContent,
        context: TerminalNotificationContext
    ) -> UNNotificationRequest {
        let native = UNMutableNotificationContent()
        native.title = content.title.isEmpty ? "VVTerm" : content.title
        native.body = content.body
        native.sound = .default
        native.threadIdentifier = context.paneId.uuidString
        native.userInfo = [
            "paneId": context.paneId.uuidString,
            "tabId": context.tabId.uuidString,
            "serverId": context.serverId.uuidString
        ]
        // No remote URLs, attachments, categories, actions, or markup are interpreted.
        // The OS rejects delivery if permission is unavailable. Terminal I/O never waits.
        return UNNotificationRequest(identifier: UUID().uuidString, content: native, trigger: nil)
    }

    nonisolated static func openContext(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> TerminalNotificationContext? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              let pane = userInfo["paneId"] as? String, let paneId = UUID(uuidString: pane),
              let tab = userInfo["tabId"] as? String, let tabId = UUID(uuidString: tab),
              let server = userInfo["serverId"] as? String, let serverId = UUID(uuidString: server) else { return nil }
        return .init(paneId: paneId, tabId: tabId, serverId: serverId)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let context = Self.openContext(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        ) else { return }
        await MainActor.run { self.onOpen(context) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
