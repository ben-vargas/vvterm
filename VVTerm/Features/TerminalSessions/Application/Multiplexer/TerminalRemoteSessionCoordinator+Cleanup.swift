import Foundation
import os.log

@MainActor
extension TerminalRemoteSessionCoordinator {
    func startPendingCleanup(for paneID: UUID) {
        for (key, state) in cleanupStates {
            guard case .pending(let owner, let client, let runtime) = state,
                  owner == paneID else { continue }
            let task = Task { [weak self, remoteSessions] in
                let trace = await client.startupTrace
                let token = trace?.begin(.sessionCleanup)
                do {
                    try await remoteSessions.cleanupSessions(
                        keeping: { [weak self] in
                            guard let self else { throw CancellationError() }
                            try Task.checkCancellation()
                            return await self.managedIdentifiers(backendIdentifier: runtime.backendIdentifier)
                        },
                        using: client,
                        runtime: runtime
                    )
                    if let token { trace?.end(token, outcome: Task.isCancelled ? "cancelled" : "ok") }
                    guard !Task.isCancelled else { return }
                    self?.cleanupStates[key] = .completed
                } catch {
                    if let token { trace?.end(token, outcome: Task.isCancelled ? "cancelled" : "failed") }
                    guard !Task.isCancelled else { return }
                    self?.logger.warning("Remote session cleanup failed: \(error.localizedDescription, privacy: .public)")
                    self?.cleanupStates.removeValue(forKey: key)
                }
            }
            cleanupStates[key] = .running(paneID: paneID, task: task)
        }
    }

    func cancelCleanup(for paneID: UUID) {
        for (key, state) in cleanupStates {
            switch state {
            case .pending(let owner, _, _) where owner == paneID:
                cleanupStates.removeValue(forKey: key)
            case .running(let owner, let task) where owner == paneID:
                task.cancel()
                cleanupStates.removeValue(forKey: key)
            default:
                break
            }
        }
    }

    func cancelAllCleanup() {
        for state in cleanupStates.values {
            if case .running(_, let task) = state { task.cancel() }
        }
        cleanupStates.removeAll()
    }
}
