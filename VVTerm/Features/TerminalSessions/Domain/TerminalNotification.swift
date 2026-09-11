import Foundation

nonisolated struct TerminalNotificationContext: Hashable, Sendable {
    let paneId: UUID
    let tabId: UUID
    let serverId: UUID
}

nonisolated struct TerminalNotificationContent: Equatable, Sendable {
    static let titleByteLimit = 256
    static let bodyByteLimit = 4096
    let title: String
    let body: String

    init(title: String, body: String) {
        self.title = Self.bounded(title, bytes: Self.titleByteLimit)
        self.body = Self.bounded(body, bytes: Self.bodyByteLimit)
    }

    private static func bounded(_ text: String, bytes: Int) -> String {
        let result = String(decoding: text.utf8.prefix(bytes), as: UTF8.self)
        // Decoding a cut UTF-8 scalar can add a replacement character. Remove it
        // if those bytes exceed the limit; never split a Swift Character.
        return result.utf8.count <= bytes ? result : String(result.dropLast())
    }

}

nonisolated enum TerminalNotificationAuthorization: Hashable, Sendable {
    case notDetermined
    case authorized
    case denied
    case unavailable
}

@MainActor
protocol TerminalNotificationSending: AnyObject {
    func authorization() async -> TerminalNotificationAuthorization
    func requestAuthorization() async -> TerminalNotificationAuthorization
    func post(_ content: TerminalNotificationContent, context: TerminalNotificationContext)
}
