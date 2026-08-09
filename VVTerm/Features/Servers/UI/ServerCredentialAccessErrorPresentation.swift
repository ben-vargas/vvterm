import Foundation

extension ServerCredentialAccessError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .approvalRequired:
            return String(
                localized: "Stored credentials are linked to another server endpoint. Approve this endpoint before using them."
            )
        }
    }
}
