import Foundation

@MainActor
struct TerminalAttachmentRoute {
    var isCurrent: @MainActor () -> Bool = { true }
    let upload: @MainActor (TerminalAttachmentPayload) async throws -> RemoteClipboardUpload
    let remove: @MainActor ([RemoteClipboardUpload]) async throws -> Void
}
