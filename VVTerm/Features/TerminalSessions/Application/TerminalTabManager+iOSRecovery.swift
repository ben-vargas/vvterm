#if os(iOS)
import Foundation

extension TerminalTabManager {
    func handleIOSNetworkReadinessChange(_ readiness: TerminalNetworkReadiness) {
        switch readiness {
        case .unknown:
            return

        case .unavailable:
            let activeReconnectPaneIDs = reconnectCoordinator.activePaneIDs
            let candidatePaneIDs: [UUID] = sessionState.allPaneStates.compactMap { paneState in
                guard paneState.hasEstablishedConnection,
                      (paneState.connectionState.isConnecting
                        || activeReconnectPaneIDs.contains(paneState.paneId)) else {
                    return nil
                }
                return paneState.paneId
            }
            for paneId in candidatePaneIDs {
                queueIOSReconnectUntilNetworkReady(for: paneId)
            }

        case .ready:
            guard case .resume(let generation) = iosNetworkRecoveryGate.receive(
                .ready,
                shouldWait: false
            ) else { return }
            reconnectCoordinator.networkBecameReady(for: generation)
        }
    }

    @discardableResult
    func queueIOSReconnectUntilNetworkReady(
        for paneId: UUID,
        replacingCurrent: Bool = true
    ) -> Bool {
        guard case .wait(let generation) = iosNetworkRecoveryGate.receive(
            .unavailable,
            shouldWait: true
        ) else { return false }
        return requestReconnectWaitingForNetwork(
            for: paneId,
            generation: generation,
            replacingCurrent: replacingCurrent
        )
    }
}
#endif
