import Foundation

nonisolated struct ClipboardImagePayload: Sendable {
    let data: Data
    let mimeType: String
    let utType: String
    let suggestedExtension: String

    var sizeBytes: Int { data.count }
}
