import Foundation

nonisolated extension ServerStatsCollectionState {
    var errorMessage: String? {
        switch phase {
        case .approvalRequired(let request):
            switch request.kind {
            case .credentialEndpoint:
                return String(localized: "Credential endpoint approval is required.")
            case .hostKey:
                return String(localized: "SSH host key approval is required before authentication.")
            }
        case .failed(let message):
            return message
        case .idle, .starting, .collecting:
            return nil
        }
    }
}

@MainActor
extension ServerStatsCollector {
    var connectionError: String? {
        collectionState.errorMessage
    }
}

nonisolated extension ProcessControlError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Stats is not connected to the server.")
        case .protectedProcess:
            return String(localized: "This process cannot be killed from Stats.")
        }
    }
}
