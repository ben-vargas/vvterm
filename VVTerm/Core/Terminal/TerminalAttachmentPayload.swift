import Foundation
import UniformTypeIdentifiers

nonisolated struct TerminalAttachmentPayload: Identifiable, Sendable {
    let id: UUID
    let data: Data
    let contentType: UTType
    let suggestedFilename: String

    init(id: UUID = UUID(), data: Data, contentType: UTType, suggestedFilename: String) {
        self.id = id
        self.data = data
        self.contentType = contentType
        let name = suggestedFilename.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        self.suggestedFilename = name.isEmpty ? "attachment.\(contentType.preferredFilenameExtension ?? "bin")" : name
    }

    init(image: ClipboardImagePayload) {
        self.init(data: image.data, contentType: UTType(image.utType) ?? .png,
                  suggestedFilename: "image.\(image.suggestedExtension)")
    }

    var sizeBytes: Int { data.count }
    var mimeType: String { contentType.preferredMIMEType ?? "application/octet-stream" }
    var suggestedExtension: String {
        let suffix = (suggestedFilename as NSString).pathExtension
        return suffix.isEmpty ? contentType.preferredFilenameExtension ?? "bin" : String(suffix.prefix(32))
    }
}
