import Foundation
import UniformTypeIdentifiers

nonisolated enum TerminalAttachmentLoader {
    // FileHandle reads must not block the main actor. Structured cancellation stops the next read.
    @concurrent
    static func files(_ urls: [URL]) async throws -> [TerminalAttachmentPayload] {
        guard urls.count <= TerminalAttachmentLimits.maximumCount else { throw TerminalAttachmentError.limitExceeded }
        var payloads: [TerminalAttachmentPayload] = []
        var remaining = TerminalAttachmentLimits.maximumBytes
        for url in urls {
            try Task.checkCancellation()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentTypeKey])
            guard values.isRegularFile == true else { throw TerminalAttachmentError.unreadable }
            guard let size = values.fileSize, size >= 0, size <= remaining else { throw TerminalAttachmentError.limitExceeded }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var data = Data()
            while true {
                try Task.checkCancellation()
                guard let chunk = try file.read(upToCount: min(64 * 1024, remaining - data.count + 1)), !chunk.isEmpty else { break }
                guard chunk.count <= remaining - data.count else { throw TerminalAttachmentError.limitExceeded }
                data.append(chunk)
            }
            guard data.count <= remaining else { throw TerminalAttachmentError.limitExceeded }
            remaining -= data.count
            payloads.append(TerminalAttachmentPayload(data: data, contentType: values.contentType ?? .data,
                                          suggestedFilename: url.lastPathComponent))
        }
        return payloads
    }
}
