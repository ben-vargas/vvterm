import Foundation

nonisolated enum InitialWorkspaceBootstrapState: Equatable, Sendable {
    case inactive
    case awaitingAuthoritativeRemoteState

    // Fresh devices use one record ID, so concurrent initial creation resolves to one record.
    static let workspaceID = UUID(
        uuid: (0x56, 0x56, 0x54, 0x65, 0x72, 0x6D, 0x49, 0x6E,
               0x69, 0x74, 0x69, 0x61, 0x6C, 0x57, 0x73, 0x70)
    )

    static func initial(
        hasResolvedInitialWorkspace: Bool,
        hasSeenWelcome: Bool,
        hasLocalWorkspaces: Bool,
        hasInitialWorkspace: Bool,
        hasPendingMutation: Bool
    ) -> Self {
        guard !hasResolvedInitialWorkspace else { return .inactive }
        if hasInitialWorkspace {
            return .awaitingAuthoritativeRemoteState
        }
        guard !hasSeenWelcome,
              !hasLocalWorkspaces,
              !hasPendingMutation else {
            return .inactive
        }
        return .awaitingAuthoritativeRemoteState
    }
}
