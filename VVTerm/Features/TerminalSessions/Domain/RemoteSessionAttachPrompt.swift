import Foundation

struct RemoteSessionSelectionInfo: Identifiable, Equatable {
    let attachment: RemoteSessionAttachment
    let attachedClientCount: Int?
    let containerCount: Int?

    var id: RemoteSessionIdentifier { attachment.identifier }
    var displayName: String { id.rawValue }
}

struct RemoteSessionAttachPrompt: Identifiable, Equatable {
    /// Unique shell-start request that owns this prompt.
    let id: UUID
    let paneId: UUID
    let backendName: String
    let existingSessions: [RemoteSessionSelectionInfo]
}

enum RemoteSessionAttachSelection: Equatable {
    case createManaged
    case attachExisting(RemoteSessionAttachment)
    case plainShell
}
