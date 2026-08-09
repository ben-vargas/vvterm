import Foundation
import Testing
@testable import VVTerm

struct ServerApplicationErrorPresentationTests {
    @Test
    func hostKeyApprovalExpirationKeepsItsExactDescription() {
        let failure = ServerConnectionTestFailure(
            reason: .hostKeyApprovalExpired,
            requiresCloudflareOverrides: false,
            hostKeyChallenge: nil
        )
        let expected = String(localized: "SSH host key approval expired. Try again.")

        #expect(failure.message == expected)
    }

    @Test
    func connectionFailureMessagePassesThrough() {
        let failure = ServerConnectionTestFailure(
            reason: .message("Connection refused"),
            requiresCloudflareOverrides: false,
            hostKeyChallenge: nil
        )

        #expect(failure.message == "Connection refused")
    }

    @Test
    func mapsEveryVVTermErrorToItsExactDescription() {
        let mappings: [(VVTermError, String)] = [
            (
                .proRequired(.unlimitedServers),
                String(localized: "Upgrade to Pro for unlimited servers")
            ),
            (
                .proRequired(.unlimitedWorkspaces),
                String(localized: "Upgrade to Pro for unlimited workspaces")
            ),
            (
                .proRequired(.moveIntoLockedWorkspace),
                String(localized: "Upgrade to Pro to move servers into locked workspaces")
            ),
            (
                .serverLocked("Production"),
                String(format: String(localized: "Server '%@' is locked"), "Production")
            ),
            (
                .workspaceLocked("Work"),
                String(format: String(localized: "Workspace '%@' is locked"), "Work")
            ),
            (
                .moveNotAllowed(.destinationUnavailable),
                String(localized: "The destination workspace is no longer available.")
            ),
            (
                .moveNotAllowed(.unavailable),
                String(localized: "This server can't be moved to that workspace right now.")
            ),
            (
                .connectionFailed("Host unreachable"),
                String(format: String(localized: "Connection failed: %@"), "Host unreachable")
            ),
            (.authenticationFailed, String(localized: "Authentication failed")),
            (.authorizationRequired, String(localized: "Authorization is required")),
            (.serverNotFound, String(localized: "Server no longer exists.")),
            (.workspaceNotFound, String(localized: "Workspace no longer exists.")),
            (
                .workspaceDeletionChanged,
                String(localized: "The workspace changed while deletion was authorized. Review it and try again.")
            ),
            (
                .workspaceDeletionRecoveryPending,
                String(localized: "The workspace was deleted, but cleanup is still pending and will retry.")
            ),
            (.timeout, String(localized: "Connection timed out"))
        ]

        for (error, expected) in mappings {
            #expect(error.errorDescription == expected)
            #expect(error.localizedDescription == expected)
        }
    }

    @Test
    func saveTransactionErrorKeepsItsExactDescription() {
        let error = ServerSaveTransactionError(
            originalError: FixedDescriptionError(description: "Metadata write failed"),
            rollbackError: FixedDescriptionError(description: "Credential restore failed")
        )
        let expected = String(
            format: String(localized: "The server was not saved, and its credentials could not be restored (%@). Retry the save. Original error: %@"),
            "Credential restore failed",
            "Metadata write failed"
        )

        #expect(error.originalErrorDescription == "Metadata write failed")
        #expect(error.rollbackErrorDescription == "Credential restore failed")
        #expect(error.errorDescription == expected)
        #expect(error.localizedDescription == expected)
    }
}

nonisolated private struct FixedDescriptionError: LocalizedError {
    let description: String

    nonisolated var errorDescription: String? { description }
}
