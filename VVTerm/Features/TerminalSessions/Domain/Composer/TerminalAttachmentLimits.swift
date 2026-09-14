import Foundation

nonisolated enum TerminalAttachmentLimits {
    static let maximumCount = 20
    static let maximumBytes = 100 * 1024 * 1024

    static func validate(_ payloads: [TerminalAttachmentPayload]) throws {
        guard payloads.count <= maximumCount else { throw TerminalAttachmentError.limitExceeded }
        var remaining = maximumBytes
        for payload in payloads {
            guard payload.sizeBytes <= remaining else { throw TerminalAttachmentError.limitExceeded }
            remaining -= payload.sizeBytes
        }
    }
}
