import Foundation
import UniformTypeIdentifiers

nonisolated struct RemoteFileViewerPayload: Identifiable, Hashable, Sendable {
    let previewKind: RemoteFilePreviewKind
    let entry: RemoteFileEntry
    let textPreview: String?
    let previewFileURL: URL?
    let isTruncated: Bool
    let unavailableMessage: String?
    let requiresExplicitDownload: Bool
    let previewByteCount: UInt64?

    var id: String { entry.id }

    var isInlinePreviewAvailable: Bool {
        previewKind != .unavailable && !requiresExplicitDownload
    }

    var canEditText: Bool {
        previewKind == .text && textPreview != nil && !isTruncated
    }
}

nonisolated enum RemoteFilePreviewKind: Hashable, Sendable {
    case text
    case image
    case video
    case unavailable
}

nonisolated enum RemoteFilePreviewDetector {
    private static let nullByte = UInt8(ascii: "\0")

    static func previewKind(for entry: RemoteFileEntry, data: Data) -> RemoteFilePreviewKind {
        if decodeTextPreview(from: data) != nil {
            return .text
        }

        guard let contentType = contentType(for: entry) else {
            return .unavailable
        }

        if contentType.conforms(to: .image) {
            return .image
        }

        if contentType.conforms(to: .movie) || contentType.conforms(to: .audiovisualContent) {
            return .video
        }

        return .unavailable
    }

    static func decodeTextPreview(from data: Data) -> String? {
        guard isProbablyText(data) else { return nil }

        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        if let utf16LittleEndian = String(data: data, encoding: .utf16LittleEndian) {
            return utf16LittleEndian
        }

        if let utf16BigEndian = String(data: data, encoding: .utf16BigEndian) {
            return utf16BigEndian
        }

        return nil
    }

    static func isProbablyText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }

        let sample = data.prefix(1024)
        let nullCount = sample.filter { $0 == nullByte }.count
        if nullCount > 0 {
            return false
        }

        if String(data: sample, encoding: .utf8) != nil {
            return true
        }

        return String(data: sample, encoding: .utf16LittleEndian) != nil
            || String(data: sample, encoding: .utf16BigEndian) != nil
    }

    private static func contentType(for entry: RemoteFileEntry) -> UTType? {
        let fileExtension = URL(fileURLWithPath: entry.name).pathExtension
        guard !fileExtension.isEmpty else { return nil }
        return UTType(filenameExtension: fileExtension)
    }
}
