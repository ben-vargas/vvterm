import Foundation

nonisolated struct TerminalRemoteSessionAttachmentState: Codable, Equatable, Sendable {
    let attachment: RemoteSessionAttachment
    var managedSessionConfirmed: Bool
}
