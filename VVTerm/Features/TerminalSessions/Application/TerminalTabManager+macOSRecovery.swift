#if os(macOS)
import Foundation
import os

extension TerminalTabManager {
    func handleMacRecoverySignal(_ signal: MacTerminalRecoveryGate.Signal) {
        if case .sleep = signal {
            macRecoveryTask?.cancel()
            macRecoveryTask = nil
            activeMacRecoveryGeneration = nil
            activeMacRecoveryReconciliationID = nil
        }
        let action = macRecoveryGate.receive(
            signal,
            networkReadiness: currentNetworkReadiness
        )

        switch action {
        case .none:
            return

        case .waitForNetwork(let generation):
            macRecoveryTask?.cancel()
            macRecoveryTask = nil
            activeMacRecoveryGeneration = generation
            activeMacRecoveryReconciliationID = nil
            reconnectCoordinator.networkBecameUnavailable(for: generation)
            logger.info(
                "Mac wake recovery waiting for network, generation \(generation.uuidString, privacy: .public), monotonic=\(Foundation.ProcessInfo.processInfo.systemUptime, privacy: .public)"
            )
            for paneId in offlineRecoveryCandidatePaneIDs {
                _ = requestReconnectWaitingForNetwork(
                    for: paneId,
                    generation: generation,
                    replacingCurrent: true
                )
            }

        case .recover(let generation):
            let reconciliationID = UUID()
            activeMacRecoveryGeneration = generation
            activeMacRecoveryReconciliationID = reconciliationID
            logger.info(
                "Mac wake recovery started, generation \(generation.uuidString, privacy: .public), monotonic=\(Foundation.ProcessInfo.processInfo.systemUptime, privacy: .public)"
            )
            reconnectCoordinator.networkBecameReady(for: generation)
            macRecoveryTask?.cancel()
            macRecoveryTask = Task { [weak self] in
                await self?.reconcileAfterMacWake(
                    generation: generation,
                    reconciliationID: reconciliationID
                )
            }
        }
    }

    private var staleRecoveryCandidates: [(
        paneId: UUID,
        strategy: MacTerminalRecoveryPolicy.ReadyStrategy
    )] {
        paneStates.values.compactMap { paneState in
            let strategy = MacTerminalRecoveryPolicy.readyStrategy(
                connectionState: paneState.connectionState,
                hasEstablishedConnection: paneState.hasEstablishedConnection,
                activeTransport: paneState.activeTransport,
                hasEternalTerminalRuntime: existingEternalTerminalRuntime(
                    for: paneState.paneId
                ) != nil
            )
            return strategy == .ignore ? nil : (paneState.paneId, strategy)
        }
    }

    private var offlineRecoveryCandidatePaneIDs: [UUID] {
        paneStates.values.compactMap { paneState in
            MacTerminalRecoveryPolicy.shouldPrepareWhileOffline(
                connectionState: paneState.connectionState,
                hasEstablishedConnection: paneState.hasEstablishedConnection
            ) ? paneState.paneId : nil
        }
    }

    private func reconcileAfterMacWake(
        generation: UUID,
        reconciliationID: UUID
    ) async {
        let candidates = staleRecoveryCandidates
        var eternalTerminalProbeIDs: [UUID: UUID] = [:]
        for candidate in candidates
        where candidate.strategy == .allowEternalTerminalSelfRecovery {
            let paneId = candidate.paneId
            if let probeID = await beginEternalTerminalNetworkRecoveryProbe(for: paneId) {
                eternalTerminalProbeIDs[paneId] = probeID
            }
            guard isCurrentMacRecovery(
                generation: generation,
                reconciliationID: reconciliationID
            ) else { return }
        }
        if !eternalTerminalProbeIDs.isEmpty {
            try? await Task.sleep(for: .seconds(5))
        }

        for candidate in candidates {
            let paneId = candidate.paneId
            guard isCurrentMacRecovery(
                generation: generation,
                reconciliationID: reconciliationID
            ) else { return }
            guard paneStates[paneId] != nil else { continue }

            let transportIsLive = await hasVerifiedLiveTransport(
                for: paneId,
                eternalTerminalProbeID: eternalTerminalProbeIDs[paneId]
            )
            guard isCurrentMacRecovery(
                generation: generation,
                reconciliationID: reconciliationID
            ) else { return }

            if transportIsLive {
                logger.info(
                    "Preserved live transport after Mac wake for pane \(paneId.uuidString, privacy: .public)"
                )
                if paneStates[paneId]?.activeTransport == .mosh,
                   paneStates[paneId]?.connectionState.isConnected != true {
                    updatePaneState(paneId, connectionState: .connected)
                }
                continue
            }

            _ = requestReconnect(
                for: paneId,
                requiresReadyNetwork: true,
                generation: generation,
                replacingCurrent: true
            )
        }
        if isCurrentMacRecovery(
            generation: generation,
            reconciliationID: reconciliationID
        ) {
            macRecoveryGate.complete(generation)
            activeMacRecoveryGeneration = nil
            activeMacRecoveryReconciliationID = nil
            macRecoveryTask = nil
        }
    }

    private func isCurrentMacRecovery(
        generation: UUID,
        reconciliationID: UUID
    ) -> Bool {
        activeMacRecoveryGeneration == generation
            && activeMacRecoveryReconciliationID == reconciliationID
            && currentNetworkReadiness == .ready
            && !Task.isCancelled
    }
}
#endif
