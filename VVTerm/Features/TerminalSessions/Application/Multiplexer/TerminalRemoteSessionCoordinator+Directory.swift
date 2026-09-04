import Foundation

@MainActor
extension TerminalRemoteSessionCoordinator {
    func startDirectoryRefresh(for paneID: UUID) {
        guard case .pending(let client, let runtime) = directoryRefreshes[paneID],
              let attachment = resolver.attachment(for: paneID)?.attachment else { return }
        let previousDirectory = sessionState.paneState(for: paneID)?.workingDirectory
        let task = Task { @concurrent [weak self, remoteSessions] in
            let directory = await remoteSessions.currentWorkingDirectory(
                for: attachment, using: client, runtime: runtime
            )
            await self?.finishDirectoryRefresh(
                for: paneID, attachment: attachment,
                previousDirectory: previousDirectory, directory: directory
            )
        }
        directoryRefreshes[paneID] = .running(task)
    }

    func cancelDirectoryRefresh(for paneID: UUID) {
        if case .running(let task) = directoryRefreshes.removeValue(forKey: paneID) {
            task.cancel()
        }
    }

    private func finishDirectoryRefresh(
        for paneID: UUID,
        attachment: RemoteSessionAttachment,
        previousDirectory: String?,
        directory: String?
    ) {
        guard !Task.isCancelled else { return }
        directoryRefreshes.removeValue(forKey: paneID)
        guard let directory,
              resolver.attachment(for: paneID)?.attachment == attachment,
              let pane = sessionState.paneState(for: paneID),
              pane.workingDirectory == previousDirectory else { return }
        // A newer directory reported by the terminal takes precedence.
        sessionState.updatePane(paneID, persist: true) { $0.workingDirectory = directory }
    }
}
