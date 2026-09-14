#if os(iOS)
import CoreTransferable
import UniformTypeIdentifiers

nonisolated struct TerminalPhotoLibraryAttachment: Transferable {
    let payload: TerminalAttachmentPayload

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie, importing: load)
        FileRepresentation(importedContentType: .image, importing: load)
    }

    private static func load(_ file: ReceivedTransferredFile) async throws -> Self {
        // Read within the import callback: Photos owns the temporary file's lifetime.
        // The shared loader checks size before reading a potentially large video.
        let payloads = try await TerminalAttachmentLoader.files([file.file])
        guard let payload = payloads.first else { throw TerminalAttachmentError.unreadable }
        return Self(payload: payload)
    }
}
#endif
