import Foundation
import UniformTypeIdentifiers

nonisolated struct ClipboardSnapshot: Sendable {
    let text: String?
    let attachments: [TerminalAttachmentPayload]

    var hasText: Bool { text?.isEmpty == false }
    var hasImage: Bool { image != nil }

    /// Direct rich paste retains its single-image confirmation and remote clipboard behavior.
    var image: ClipboardImagePayload? {
        guard let attachment = attachments.first(where: { $0.contentType.conforms(to: .image) }) else { return nil }
        return ClipboardImagePayload(data: attachment.data, mimeType: attachment.mimeType,
                                     utType: attachment.contentType.identifier, suggestedExtension: attachment.suggestedExtension)
    }
}
