import Foundation

@MainActor
extension TerminalRemoteSessionCoordinator {
    func managedSessionIdentifierToKill(
        for paneID: UUID,
        status: RemoteSessionStatus
    ) -> RemoteSessionIdentifier? {
        guard status == .foreground || status == .background,
              let state = resolver.attachment(for: paneID),
              state.attachment.ownership == .managed else {
            return nil
        }
        return state.attachment.identifier
    }

    func killIfNeeded(for paneID: UUID) {
        guard let registration = transportLifetime.registry.shellRegistration(for: paneID),
              let state = resolver.attachment(for: paneID),
              state.attachment.ownership == .managed else {
            return
        }
        let identifier = state.attachment.identifier
        Task.detached { [remoteSessions, identifier, client = registration.client] in
            await remoteSessions.killSession(identifier, using: client, runtime: nil)
        }
    }

    func killSession(
        _ identifier: RemoteSessionIdentifier,
        using client: SSHClient
    ) async {
        await remoteSessions.killSession(identifier, using: client, runtime: nil)
    }

    func killSession(
        _ identifier: RemoteSessionIdentifier,
        using runtime: EternalTerminalRuntime
    ) async {
        await runtime.killManagedRemoteSession(identifier)
    }

    func resetRuntimeState(for paneIDs: Set<UUID>) {
        for paneID in paneIDs {
            clearRuntimeState(for: paneID)
        }
        resolver.cancelAllPrompts()
        for paneID in directoryRefreshes.keys { cancelDirectoryRefresh(for: paneID) }
        cancelAllCleanup()
    }
}
