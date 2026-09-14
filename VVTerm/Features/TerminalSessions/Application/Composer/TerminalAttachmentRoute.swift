import Foundation

@MainActor
struct TerminalAttachmentRoute {
    let upload: @MainActor (TerminalAttachmentPayload) async throws -> RemoteClipboardUpload
    let remove: @MainActor ([RemoteClipboardUpload]) async -> Void
    let submit: @MainActor (String, TerminalInputMode) throws -> Void
}
