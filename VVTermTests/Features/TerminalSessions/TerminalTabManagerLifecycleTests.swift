import Foundation
import Testing
@testable import VVTerm

private actor TmuxAvailabilityGate {
    private var continuation: CheckedContinuation<RemoteTmuxAvailability, Never>?

    func waitForResolution() async -> RemoteTmuxAvailability {
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked(timeout: Duration = .seconds(2)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if continuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return continuation != nil
    }

    func resolve(_ availability: RemoteTmuxAvailability) {
        continuation?.resume(returning: availability)
        continuation = nil
    }
}

@Suite(.serialized)
@MainActor
struct TerminalTabManagerLifecycleTests {
    private func makeServer(
        id: UUID = UUID(),
        name: String = "Test",
        connectionMode: SSHConnectionMode = .standard
    ) -> Server {
        Server(
            id: id,
            workspaceId: UUID(),
            name: name,
            host: "ssh.example.com",
            username: "root",
            connectionMode: connectionMode
        )
    }

    private func withCleanManager(
        _ body: @MainActor (TerminalTabManager) async throws -> Void
    ) async rethrows {
        let manager = TerminalTabManager.shared
        await manager.resetForTesting()
        do {
            try await body(manager)
            await manager.resetForTesting()
        } catch {
            await manager.resetForTesting()
            throw error
        }
    }

    private func withTmuxEnabled(
        _ body: @MainActor () async throws -> Void
    ) async rethrows {
        let defaults = UserDefaults.standard
        let key = "terminalTmuxEnabledDefault"
        let previousValue = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        try await body()
    }

    @Test
    func reconnectClearsMoshFallbackDiagnostics() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Fallback")
            installTab(tab, in: manager, connectionState: .connected)
            manager.updatePaneForTesting(tab.rootPaneId) {
                $0.transportState = .sshFallback(
                    reason: .udpTimeout,
                    diagnostics: .make(
                    reason: .udpTimeout,
                    events: [],
                    appContext: .init(version: "test", platform: "test")
                    )
                )
            }

            manager.clearMoshFallbackDiagnostics(for: tab.rootPaneId)

            #expect(manager.paneState(for: tab.rootPaneId)?.activeTransport == .sshFallback)
            #expect(manager.paneState(for: tab.rootPaneId)?.moshFallbackReason == .udpTimeout)
            #expect(manager.paneState(for: tab.rootPaneId)?.moshFallbackDiagnostics == nil)

            manager.updatePaneState(tab.rootPaneId, connectionState: .reconnecting(attempt: 1))
            #expect(manager.paneState(for: tab.rootPaneId)?.activeTransport == .ssh)
            #expect(manager.paneState(for: tab.rootPaneId)?.moshFallbackReason == nil)
        }
    }

    @Test
    func reconnectGenerationCreatesExactlyOneManagerOwnedReplacement() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Wake recovery")
            installTab(tab, in: manager, connectionState: .connected)
            manager.updatePaneState(tab.rootPaneId, connectionState: .disconnected)
            let originalTerminalGeneration = manager.terminalConnectionGeneration(
                for: tab.rootPaneId
            )
            let recoveryGeneration = UUID()

            #expect(manager.requestReconnect(
                for: tab.rootPaneId,
                requiresReadyNetwork: false,
                generation: recoveryGeneration,
                replacingCurrent: true
            ))
            #expect(!manager.requestReconnect(
                for: tab.rootPaneId,
                requiresReadyNetwork: false,
                generation: recoveryGeneration,
                replacingCurrent: true
            ))
            #expect(await waitUntil {
                manager.reconnectAttempt(for: tab.rootPaneId)?.phase == .connecting
            })
            #expect(manager.paneState(for: tab.rootPaneId)?.connectionState.isConnecting == true)
            #expect(
                manager.terminalConnectionGeneration(for: tab.rootPaneId)
                    != originalTerminalGeneration
            )

            manager.updatePaneState(tab.rootPaneId, connectionState: .connected)
            #expect(manager.reconnectAttempt(for: tab.rootPaneId) == nil)
        }
    }

    #if os(iOS)
    @Test
    func offlineReconnectWaitsWithoutStartingThenStartsExactlyOnceWhenReady() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Offline recovery")
            installTab(tab, in: manager, connectionState: .connected)
            manager.updatePaneState(tab.rootPaneId, connectionState: .disconnected)
            let originalTerminalGeneration = manager.terminalConnectionGeneration(
                for: tab.rootPaneId
            )

            #expect(manager.requestReconnect(
                for: tab.rootPaneId,
                requiresReadyNetwork: false,
                generation: UUID(),
                replacingCurrent: false,
                networkReadiness: .unavailable
            ))
            #expect(!manager.requestReconnect(
                for: tab.rootPaneId,
                requiresReadyNetwork: false,
                generation: UUID(),
                replacingCurrent: false,
                networkReadiness: .unavailable
            ))
            #expect(await waitUntil {
                manager.reconnectAttempt(for: tab.rootPaneId)?.phase == .waitingForNetwork
            })
            #expect(
                manager.terminalConnectionGeneration(for: tab.rootPaneId)
                    == originalTerminalGeneration
            )
            #expect(manager.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)

            manager.handleIOSNetworkReadinessChange(.ready)
            #expect(await waitUntil {
                manager.reconnectAttempt(for: tab.rootPaneId)?.phase == .connecting
            })
            let replacementGeneration = manager.terminalConnectionGeneration(
                for: tab.rootPaneId
            )
            #expect(replacementGeneration != originalTerminalGeneration)

            manager.handleIOSNetworkReadinessChange(.ready)
            await Task.yield()
            #expect(
                manager.terminalConnectionGeneration(for: tab.rootPaneId)
                    == replacementGeneration
            )
        }
    }

    @Test
    func networkDropAfterReconnectIsQueuedWaitsForReady() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Mid-cleanup network loss")
            installTab(tab, in: manager, connectionState: .connected)
            manager.updatePaneState(tab.rootPaneId, connectionState: .disconnected)
            let originalTerminalGeneration = manager.terminalConnectionGeneration(
                for: tab.rootPaneId
            )

            #expect(manager.requestReconnect(
                for: tab.rootPaneId,
                requiresReadyNetwork: false,
                generation: UUID(),
                replacingCurrent: true,
                networkReadiness: .ready
            ))
            manager.handleIOSNetworkReadinessChange(.unavailable)

            #expect(await waitUntil {
                manager.reconnectAttempt(for: tab.rootPaneId)?.phase == .waitingForNetwork
            })
            #expect(
                manager.terminalConnectionGeneration(for: tab.rootPaneId)
                    == originalTerminalGeneration
            )

            manager.handleIOSNetworkReadinessChange(.ready)
            #expect(await waitUntil {
                manager.terminalConnectionGeneration(for: tab.rootPaneId)
                    != originalTerminalGeneration
            })
            let replacementGeneration = manager.terminalConnectionGeneration(
                for: tab.rootPaneId
            )
            manager.handleIOSNetworkReadinessChange(.ready)
            await Task.yield()
            #expect(
                manager.terminalConnectionGeneration(for: tab.rootPaneId)
                    == replacementGeneration
            )
        }
    }
    #endif

    @Test
    func reconnectDetachesEternalTerminalOwnerBeforeReplacementStarts() async {
        await withCleanManager { manager in
            let server = makeServer(connectionMode: .eternalTerminal)
            let tab = TerminalTab(serverId: server.id, title: "ET recovery")
            installTab(tab, in: manager, connectionState: .connected)
            let credentials = ServerCredentials(serverId: server.id)
            let oldRuntime = manager.eternalTerminalRuntime(
                for: tab.rootPaneId,
                server: server,
                credentials: credentials
            )

            #expect(manager.requestReconnect(
                for: tab.rootPaneId,
                requiresReadyNetwork: false,
                generation: UUID(),
                replacingCurrent: true
            ))
            #expect(await waitUntil {
                !manager.isCurrentEternalTerminalRuntime(oldRuntime, for: tab.rootPaneId)
            })

            let replacement = manager.eternalTerminalRuntime(
                for: tab.rootPaneId,
                server: server,
                credentials: credentials
            )
            await manager.unregisterEternalTerminalRuntime(
                for: tab.rootPaneId,
                ifOwnedBy: oldRuntime
            )
            #expect(manager.isCurrentEternalTerminalRuntime(replacement, for: tab.rootPaneId))
        }
    }

    #if os(macOS)
    @Test
    func macWakeSignalsCreateExactlyOneManagerOwnedReplacement() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Mac wake recovery")
            installTab(tab, in: manager, connectionState: .connected)
            let originalTerminalGeneration = manager.terminalConnectionGeneration(
                for: tab.rootPaneId
            )
            #expect(await waitUntil { NetworkMonitor.shared.readiness == .ready })

            manager.handleMacRecoverySignal(.sleep)
            manager.handleMacRecoverySignal(.wake)
            manager.handleMacRecoverySignal(.applicationActivated)
            manager.handleMacRecoverySignal(.networkChanged(.ready))

            #expect(await waitUntil {
                manager.terminalConnectionGeneration(for: tab.rootPaneId)
                    != originalTerminalGeneration
            })
            let replacementGeneration = manager.terminalConnectionGeneration(
                for: tab.rootPaneId
            )

            manager.handleMacRecoverySignal(.wake)
            manager.handleMacRecoverySignal(.applicationActivated)
            await Task.yield()
            #expect(
                manager.terminalConnectionGeneration(for: tab.rootPaneId)
                    == replacementGeneration
            )
        }
    }

    @Test
    func macNetworkDropAfterReconnectIsQueuedWaitsForReady() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Mac mid-cleanup network loss")
            installTab(tab, in: manager, connectionState: .connected)
            manager.updatePaneState(tab.rootPaneId, connectionState: .disconnected)
            let originalTerminalGeneration = manager.terminalConnectionGeneration(
                for: tab.rootPaneId
            )

            _ = manager.macRecoveryGate.receive(.sleep, networkReadiness: .ready)
            guard case .recover(let recoveryGeneration) = manager.macRecoveryGate.receive(
                .wake,
                networkReadiness: .ready
            ) else {
                Issue.record("Expected a Mac recovery generation")
                return
            }
            manager.activeMacRecoveryGeneration = recoveryGeneration

            #expect(manager.requestReconnect(
                for: tab.rootPaneId,
                requiresReadyNetwork: false,
                generation: recoveryGeneration,
                replacingCurrent: true,
                networkReadiness: .ready
            ))
            manager.handleMacRecoverySignal(.networkChanged(.unavailable))

            #expect(await waitUntil {
                manager.reconnectAttempt(for: tab.rootPaneId)?.phase == .waitingForNetwork
            })
            #expect(
                manager.terminalConnectionGeneration(for: tab.rootPaneId)
                    == originalTerminalGeneration
            )

            manager.handleMacRecoverySignal(.networkChanged(.ready))
            #expect(await waitUntil {
                manager.terminalConnectionGeneration(for: tab.rootPaneId)
                    != originalTerminalGeneration
            })
        }
    }
    #endif

    @Test
    func terminalZoomOnlyChangesRequestedPaneOverride() async {
        let defaults = UserDefaults.standard
        let previousFontSize = defaults.object(forKey: TerminalDefaults.fontSizeKey)
        defaults.set(12.0, forKey: TerminalDefaults.fontSizeKey)
        defer {
            if let previousFontSize {
                defaults.set(previousFontSize, forKey: TerminalDefaults.fontSizeKey)
            } else {
                defaults.removeObject(forKey: TerminalDefaults.fontSizeKey)
            }
        }

        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Pane zoom")
            installTab(tab, in: manager, connectionState: .connected)
            let siblingPaneId = UUID()
            manager.setPaneStateForTesting(TerminalPaneState(
                paneId: siblingPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            ))

            let result = manager.handleTerminalZoom(.zoomIn, for: tab.rootPaneId)

            #expect(result?.effectiveFontSize == 13.0)
            #expect(manager.presentationOverrides(for: tab.rootPaneId).fontSize == 13.0)
            #expect(manager.presentationOverrides(for: siblingPaneId).isEmpty)
            #expect(defaults.double(forKey: TerminalDefaults.fontSizeKey) == 12.0)
        }
    }

    @Test
    func successfulMoshRegistrationReplacesFallbackDiagnostics() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Mosh recovery")
            installTab(tab, in: manager, connectionState: .connected)
            manager.updatePaneForTesting(tab.rootPaneId) {
                $0.transportState = .sshFallback(
                    reason: .udpTimeout,
                    diagnostics: .make(
                    reason: .udpTimeout,
                    events: [],
                    appContext: .init(version: "test", platform: "test")
                    )
                )
            }

            let client = SSHClient()
            #expect(await startAndRegisterShell(
                client,
                paneId: tab.rootPaneId,
                serverId: tab.serverId,
                transportState: .mosh,
                in: manager
            ))
            #expect(manager.paneState(for: tab.rootPaneId)?.activeTransport == .mosh)
            #expect(manager.paneState(for: tab.rootPaneId)?.moshFallbackReason == nil)
            #expect(manager.paneState(for: tab.rootPaneId)?.moshFallbackDiagnostics == nil)
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }

    private func installTab(
        _ tab: TerminalTab,
        in manager: TerminalTabManager,
        connectionState: ConnectionState = .connecting
    ) {
        manager.installTabForTesting(tab, paneState: TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        ))
        manager.updatePaneState(tab.rootPaneId, connectionState: connectionState)
    }

    private func startAndRegisterShell(
        _ client: SSHClient,
        shellId: UUID = UUID(),
        paneId: UUID,
        serverId: UUID,
        transportState: ShellTransportState = .ssh,
        in manager: TerminalTabManager
    ) async -> Bool {
        guard let startToken = manager.beginShellStart(for: paneId, client: client) else {
            return false
        }
        return await manager.registerSSHClient(
            client,
            shellId: shellId,
            startToken: startToken,
            for: paneId,
            serverId: serverId,
            transportState: transportState
        )
    }

    @Test
    func staleExitCannotUnregisterReplacementShell() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Replacement shell")
            installTab(tab, in: manager)
            let oldClient = SSHClient()
            let oldShellId = UUID()

            #expect(await startAndRegisterShell(
                oldClient,
                shellId: oldShellId,
                paneId: tab.rootPaneId,
                serverId: tab.serverId,
                in: manager
            ))
            await manager.unregisterSSHClient(for: tab.rootPaneId)

            let replacementClient = SSHClient()
            let replacementShellId = UUID()
            #expect(await startAndRegisterShell(
                replacementClient,
                shellId: replacementShellId,
                paneId: tab.rootPaneId,
                serverId: tab.serverId,
                in: manager
            ))

            await manager.unregisterSSHClient(
                for: tab.rootPaneId,
                ifOwnedBy: oldClient,
                shellId: oldShellId
            )

            #expect(manager.activeSSHRoute(for: tab.rootPaneId)?.shellId == replacementShellId)
            #expect(manager.activeSSHRoute(for: tab.rootPaneId)?.client === replacementClient)
        }
    }

    @Test
    func currentSurfaceExitCancelsPendingStartWithoutRemovingReplacement() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Pending surface exit")
            installTab(tab, in: manager)
            let exitedSurfaceClient = SSHClient()

            guard let exitedStartToken = manager.beginShellStart(
                for: tab.rootPaneId,
                client: exitedSurfaceClient
            ), let exitedConnectionToken = manager.connectionOwnershipToken(for: tab.rootPaneId) else {
                Issue.record("Expected the exiting surface to own a shell start")
                return
            }
            #expect(exitedConnectionToken == exitedStartToken)
            #expect(manager.isCurrentShellOwner(
                for: tab.rootPaneId,
                client: exitedSurfaceClient,
                startToken: exitedStartToken
            ))

            await manager.unregisterSSHClient(
                for: tab.rootPaneId,
                ifOwnedBy: exitedConnectionToken
            )
            #expect(!manager.isTransportStartInFlight(for: tab.rootPaneId))

            guard let replacementStartToken = manager.beginShellStart(
                for: tab.rootPaneId,
                client: exitedSurfaceClient
            ) else {
                Issue.record("Expected a same-client replacement shell start")
                return
            }

            await manager.unregisterSSHClient(
                for: tab.rootPaneId,
                ifOwnedBy: exitedConnectionToken
            )
            #expect(manager.isTransportStartInFlight(for: tab.rootPaneId))
            #expect(manager.isCurrentShellOwner(
                for: tab.rootPaneId,
                client: exitedSurfaceClient,
                startToken: replacementStartToken
            ))
        }
    }

    @Test
    func staleRegistrationFromDifferentClientDoesNotReplacePendingStart() async {
        await withCleanManager { manager in
            let serverId = UUID()
            let tab = TerminalTab(serverId: serverId, title: "Pending")
            installTab(tab, in: manager)

            let activeClient = SSHClient()
            let staleClient = SSHClient()
            guard let activeStartToken = manager.beginShellStart(
                for: tab.rootPaneId,
                client: activeClient
            ) else {
                Issue.record("Expected active shell start")
                return
            }

            #expect(!(await manager.registerSSHClient(
                staleClient,
                shellId: UUID(),
                startToken: activeStartToken,
                for: tab.rootPaneId,
                serverId: serverId
            )))

            #expect(manager.activeSSHRoute(for: tab.rootPaneId) == nil)
            #expect(manager.isTransportStartInFlight(for: tab.rootPaneId))

            manager.finishShellStart(
                for: tab.rootPaneId,
                client: staleClient,
                startToken: activeStartToken
            )
            #expect(manager.isTransportStartInFlight(for: tab.rootPaneId))

            manager.finishShellStart(
                for: tab.rootPaneId,
                client: activeClient,
                startToken: activeStartToken
            )
            #expect(!manager.isTransportStartInFlight(for: tab.rootPaneId))
        }
    }

    @Test
    func unregisterWithoutShellClearsPendingStart() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Pending")
            installTab(tab, in: manager)

            let firstClient = SSHClient()
            #expect(manager.beginShellStart(for: tab.rootPaneId, client: firstClient) != nil)

            await manager.unregisterSSHClient(for: tab.rootPaneId)

            #expect(!manager.isTransportStartInFlight(for: tab.rootPaneId))
            #expect(manager.activeSSHRoute(for: tab.rootPaneId) == nil)

            let nextClient = SSHClient()
            guard let nextStartToken = manager.beginShellStart(
                for: tab.rootPaneId,
                client: nextClient
            ) else {
                Issue.record("Expected replacement shell start")
                return
            }
            manager.finishShellStart(
                for: tab.rootPaneId,
                client: nextClient,
                startToken: nextStartToken
            )
        }
    }

    @Test
    func unregisterPendingShellStartCancelsItsTmuxPrompt() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Pending prompt")
            installTab(tab, in: manager)
            let client = SSHClient()
            guard let startToken = manager.beginShellStart(
                for: tab.rootPaneId,
                client: client
            ) else {
                Issue.record("Expected pending shell start")
                return
            }

            let selection = Task { @MainActor in
                await manager.tmuxCoordinator.requestSelection(
                    requestId: startToken.id,
                    paneId: tab.rootPaneId,
                    serverId: tab.serverId,
                    availableSessions: []
                )
            }
            guard await waitUntil({
                manager.tmuxCoordinator.hasPendingPrompt(requestId: startToken.id)
            }) else {
                Issue.record("Pending tmux prompt was not enqueued")
                selection.cancel()
                return
            }

            await manager.unregisterSSHClient(for: tab.rootPaneId)

            let promptWasCancelled = await waitUntil({
                !manager.tmuxCoordinator.hasPendingPrompt(requestId: startToken.id)
                    && manager.tmuxCoordinator.attachPrompt == nil
            })
            #expect(promptWasCancelled)
            if !promptWasCancelled {
                selection.cancel()
            }
            #expect(await selection.value == .skipTmux)
        }
    }

    @Test
    func onlyCurrentPaneClientCanContinueConnecting() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Pending")
            installTab(tab, in: manager)
            let activeClient = SSHClient()
            let staleClient = SSHClient()

            guard let activeStartToken = manager.beginShellStart(
                for: tab.rootPaneId,
                client: activeClient
            ) else {
                Issue.record("Expected active shell start")
                return
            }
            #expect(manager.isCurrentShellOwner(
                for: tab.rootPaneId,
                client: activeClient,
                startToken: activeStartToken
            ))
            #expect(!manager.isCurrentShellOwner(
                for: tab.rootPaneId,
                client: staleClient,
                startToken: activeStartToken
            ))

            await manager.unregisterSSHClient(for: tab.rootPaneId)

            #expect(!manager.isCurrentShellOwner(
                for: tab.rootPaneId,
                client: activeClient,
                startToken: activeStartToken
            ))
        }
    }

    @Test
    func shellStartFailsWhenPaneIsMissing() async {
        await withCleanManager { manager in
            let missingPaneId = UUID()

            #expect(manager.beginShellStart(for: missingPaneId, client: SSHClient()) == nil)
            #expect(!manager.isTransportStartInFlight(for: missingPaneId))
        }
    }

    @Test
    func disconnectServerLeavesOtherServerTabsAndShellsConnected() async {
        await withCleanManager { manager in
            let firstTab = TerminalTab(serverId: UUID(), title: "First")
            let secondTab = TerminalTab(serverId: UUID(), title: "Second")
            installTab(firstTab, in: manager)
            installTab(secondTab, in: manager)

            let firstClient = SSHClient()
            let secondClient = SSHClient()
            #expect(await startAndRegisterShell(
                firstClient,
                paneId: firstTab.rootPaneId,
                serverId: firstTab.serverId,
                in: manager
            ))
            #expect(await startAndRegisterShell(
                secondClient,
                paneId: secondTab.rootPaneId,
                serverId: secondTab.serverId,
                in: manager
            ))
            manager.updatePaneState(firstTab.rootPaneId, connectionState: .connected)
            manager.updatePaneState(secondTab.rootPaneId, connectionState: .connected)

            manager.disconnectServer(firstTab.serverId)

            #expect(manager.tabs(for: firstTab.serverId).isEmpty)
            #expect(manager.paneState(for: firstTab.rootPaneId) == nil)
            #expect(!manager.connectedServerIds.contains(firstTab.serverId))
            #expect(manager.tabs(for: secondTab.serverId) == [secondTab])
            #expect(manager.paneState(for: secondTab.rootPaneId)?.connectionState == .connected)
            #expect(manager.activeSSHRoute(for: secondTab.rootPaneId) != nil)
            #expect(manager.connectedServerIds == [secondTab.serverId])
        }
    }

    @Test
    func staleShellOnSharedClientDoesNotDisconnectSiblingPane() async {
        await withCleanManager { manager in
            let siblingTab = TerminalTab(serverId: UUID(), title: "Sibling")
            let pendingTab = TerminalTab(serverId: UUID(), title: "Pending")
            installTab(siblingTab, in: manager)
            installTab(pendingTab, in: manager)

            let sharedClient = SSHClient()
            #expect(await startAndRegisterShell(
                sharedClient,
                paneId: siblingTab.rootPaneId,
                serverId: siblingTab.serverId,
                in: manager
            ))

            let pendingClient = SSHClient()
            guard let pendingStartToken = manager.beginShellStart(
                for: pendingTab.rootPaneId,
                client: pendingClient
            ) else {
                Issue.record("Expected pending shell start")
                return
            }
            #expect(!(await manager.registerSSHClient(
                sharedClient,
                shellId: UUID(),
                startToken: pendingStartToken,
                for: pendingTab.rootPaneId,
                serverId: pendingTab.serverId
            )))

            #expect(!(await sharedClient.isAborted))
            #expect(manager.activeSSHRoute(for: siblingTab.rootPaneId)?.client === sharedClient)
            #expect(manager.isCurrentShellOwner(
                for: pendingTab.rootPaneId,
                client: pendingClient,
                startToken: pendingStartToken
            ))
        }
    }

    @Test
    func shellExitLifecycleDisconnectsPaneAndClearsRegistration() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Shell Exit")
            installTab(tab, in: manager)

            let client = SSHClient()
            #expect(await startAndRegisterShell(
                client,
                paneId: tab.rootPaneId,
                serverId: tab.serverId,
                in: manager
            ))
            manager.updatePaneState(tab.rootPaneId, connectionState: .connected)

            manager.updatePaneState(tab.rootPaneId, connectionState: .disconnected)
            await manager.unregisterSSHClient(for: tab.rootPaneId)

            #expect(manager.tabs(for: tab.serverId) == [tab])
            #expect(manager.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
            #expect(manager.activeSSHRoute(for: tab.rootPaneId) == nil)
            #expect(!manager.connectedServerIds.contains(tab.serverId))
            #expect(!TerminalConnectionStartPolicy.shouldStart(connectionState: .disconnected))
        }
    }

    @Test
    func managedTmuxEndClosesItsLastPaneAndTab() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Managed tmux")
            installTab(tab, in: manager, connectionState: .connected)
            manager.tmuxCoordinator.setAttachment(
                for: tab.rootPaneId,
                sessionName: "vvterm_test",
                ownership: .managed
            )
            manager.tmuxCoordinator.updateStatus(.foreground, for: tab.rootPaneId)

            manager.handleShellEnd(for: tab.rootPaneId, reason: .tmuxEnded(.managed))

            #expect(manager.tabs(for: tab.serverId).isEmpty)
            #expect(manager.paneState(for: tab.rootPaneId) == nil)
            #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId) == nil)
        }
    }

    @Test
    func managedTmuxEndClosesOnlyItsPaneInSplitTab() async {
        await withCleanManager { manager in
            let secondPaneId = UUID()
            var tab = TerminalTab(serverId: UUID(), title: "Split tmux")
            tab.layout = .split(.init(
                direction: .horizontal,
                ratio: 0.5,
                left: .leaf(paneId: tab.rootPaneId),
                right: .leaf(paneId: secondPaneId)
            ))
            installTab(tab, in: manager, connectionState: .connected)
            manager.setPaneStateForTesting(TerminalPaneState(
                paneId: secondPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            ))
            manager.tmuxCoordinator.setAttachment(
                for: secondPaneId,
                sessionName: "vvterm_second",
                ownership: .managed
            )
            manager.tmuxCoordinator.updateStatus(.background, for: secondPaneId)

            manager.handleShellEnd(for: secondPaneId, reason: .tmuxEnded(.managed))

            let remainingTab = manager.tabs(for: tab.serverId).first
            #expect(remainingTab?.allPaneIds == [tab.rootPaneId])
            #expect(manager.paneState(for: tab.rootPaneId) != nil)
            #expect(manager.paneState(for: secondPaneId) == nil)
        }
    }

    @Test
    func managedTmuxDetachPreservesPaneAndSuppressesAutomaticReconnect() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Detached tmux")
            installTab(tab, in: manager, connectionState: .connected)
            manager.tmuxCoordinator.setAttachment(
                for: tab.rootPaneId,
                sessionName: "vvterm_test",
                ownership: .managed
            )
            manager.tmuxCoordinator.updateStatus(.foreground, for: tab.rootPaneId)

            manager.handleShellEnd(for: tab.rootPaneId, reason: .tmuxDetached(.managed))

            #expect(manager.tabs(for: tab.serverId) == [tab])
            #expect(manager.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
            #expect(manager.paneState(for: tab.rootPaneId)?.disconnectReason == .tmuxDetached)
            #expect(manager.paneState(for: tab.rootPaneId)?.disconnectReason?.allowsAutomaticReconnect == false)
            #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId)?.sessionName == "vvterm_test")
            #expect(manager.tmuxCoordinator.hasConfirmedManagedSession(for: tab.rootPaneId))
        }
    }

    @Test
    func disconnectedTmuxProbePreservesConfirmedAttachmentInsteadOfReportingMissing() async {
        await withTmuxEnabled {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Long-idle tmux reconnect")
                installTab(tab, in: manager, connectionState: .disconnected)
                manager.tmuxCoordinator.setAttachment(
                    for: tab.rootPaneId,
                    sessionName: "vvterm_existing",
                    ownership: .managed,
                    managedSessionConfirmed: true
                )
                manager.tmuxCoordinator.updateStatus(.background, for: tab.rootPaneId)

                let disconnectedClient = SSHClient()
                guard let startToken = manager.beginShellStart(
                    for: tab.rootPaneId,
                    client: disconnectedClient
                ) else {
                    Issue.record("Expected disconnected shell start")
                    return
                }

                do {
                    _ = try await manager.tmuxCoordinator.startupPlan(
                        for: tab.rootPaneId,
                        serverId: tab.serverId,
                        client: disconnectedClient,
                        startToken: startToken
                    )
                    Issue.record("An indeterminate tmux probe should retry the connection")
                } catch {
                    #expect(error is SSHError)
                }

                #expect(manager.paneState(for: tab.rootPaneId)?.tmuxStatus == .background)
                #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId) == TerminalTmuxAttachmentState(
                    sessionName: "vvterm_existing",
                    ownership: .managed,
                    managedSessionConfirmed: true
                ))
                #expect(manager.tmuxCoordinator.attachPrompt == nil)

                manager.finishShellStart(
                    for: tab.rootPaneId,
                    client: disconnectedClient,
                    startToken: startToken
                )
            }
        }
    }

    @Test
    func explicitMissingTmuxProbeClearsAttachmentAndReportsMissing() async {
        await withTmuxEnabled {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Confirmed missing tmux")
                installTab(tab, in: manager, connectionState: .disconnected)
                manager.tmuxCoordinator.setAttachment(
                    for: tab.rootPaneId,
                    sessionName: "vvterm_existing",
                    ownership: .managed,
                    managedSessionConfirmed: true
                )
                manager.tmuxCoordinator.updateStatus(.background, for: tab.rootPaneId)

                let client = SSHClient()
                guard let startToken = manager.beginShellStart(
                    for: tab.rootPaneId,
                    client: client
                ) else {
                    Issue.record("Expected shell start")
                    return
                }
                _ = try? await manager.tmuxCoordinator.startupPlan(
                    for: tab.rootPaneId,
                    serverId: tab.serverId,
                    client: client,
                    startToken: startToken,
                    availabilityResolver: { .confirmedMissing }
                )

                #expect(manager.paneState(for: tab.rootPaneId)?.tmuxStatus == .missing)
                #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId) == nil)

                manager.finishShellStart(
                    for: tab.rootPaneId,
                    client: client,
                    startToken: startToken
                )
            }
        }
    }

    @Test
    func staleMissingTmuxProbeCannotOverwriteReplacementOwner() async {
        await withTmuxEnabled {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Stale tmux probe")
                installTab(tab, in: manager, connectionState: .disconnected)
                manager.tmuxCoordinator.setAttachment(
                    for: tab.rootPaneId,
                    sessionName: "vvterm_existing",
                    ownership: .managed,
                    managedSessionConfirmed: true
                )
                manager.tmuxCoordinator.updateStatus(.background, for: tab.rootPaneId)

                let client = SSHClient()
                let gate = TmuxAvailabilityGate()
                guard let staleStartToken = manager.beginShellStart(
                    for: tab.rootPaneId,
                    client: client
                ) else {
                    Issue.record("Expected stale shell start")
                    return
                }

                let stalePlan = Task { @MainActor in
                    do {
                        _ = try await manager.tmuxCoordinator.startupPlan(
                            for: tab.rootPaneId,
                            serverId: tab.serverId,
                            client: client,
                            startToken: staleStartToken,
                            availabilityResolver: { await gate.waitForResolution() }
                        )
                        return false
                    } catch is CancellationError {
                        return true
                    } catch {
                        Issue.record("Unexpected stale probe error: \(error)")
                        return false
                    }
                }

                #expect(await gate.waitUntilBlocked())
                manager.finishShellStart(
                    for: tab.rootPaneId,
                    client: client,
                    startToken: staleStartToken
                )
                guard let replacementStartToken = manager.beginShellStart(
                    for: tab.rootPaneId,
                    client: client
                ) else {
                    Issue.record("Expected replacement shell start")
                    return
                }
                await gate.resolve(.confirmedMissing)

                #expect(await stalePlan.value)
                #expect(manager.paneState(for: tab.rootPaneId)?.tmuxStatus == .background)
                #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId) == TerminalTmuxAttachmentState(
                    sessionName: "vvterm_existing",
                    ownership: .managed,
                    managedSessionConfirmed: true
                ))

                manager.finishShellStart(
                    for: tab.rootPaneId,
                    client: client,
                    startToken: replacementStartToken
                )
            }
        }
    }

    @Test
    func cancelledTmuxProbeCannotPublishMissingForCurrentOwner() async {
        await withTmuxEnabled {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Cancelled tmux probe")
                installTab(tab, in: manager, connectionState: .disconnected)
                manager.tmuxCoordinator.setAttachment(
                    for: tab.rootPaneId,
                    sessionName: "vvterm_existing",
                    ownership: .managed,
                    managedSessionConfirmed: true
                )
                manager.tmuxCoordinator.updateStatus(.background, for: tab.rootPaneId)

                let client = SSHClient()
                let gate = TmuxAvailabilityGate()
                guard let startToken = manager.beginShellStart(
                    for: tab.rootPaneId,
                    client: client
                ) else {
                    Issue.record("Expected shell start")
                    return
                }

                let cancelledPlan = Task { @MainActor in
                    do {
                        _ = try await manager.tmuxCoordinator.startupPlan(
                            for: tab.rootPaneId,
                            serverId: tab.serverId,
                            client: client,
                            startToken: startToken,
                            availabilityResolver: { await gate.waitForResolution() }
                        )
                        return false
                    } catch is CancellationError {
                        return true
                    } catch {
                        Issue.record("Unexpected cancelled probe error: \(error)")
                        return false
                    }
                }

                #expect(await gate.waitUntilBlocked())
                cancelledPlan.cancel()
                await gate.resolve(.confirmedMissing)

                #expect(await cancelledPlan.value)
                #expect(manager.paneState(for: tab.rootPaneId)?.tmuxStatus == .background)
                #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId) == TerminalTmuxAttachmentState(
                    sessionName: "vvterm_existing",
                    ownership: .managed,
                    managedSessionConfirmed: true
                ))

                manager.finishShellStart(
                    for: tab.rootPaneId,
                    client: client,
                    startToken: startToken
                )
            }
        }
    }

    @Test
    func cancelledTmuxPromptCannotResolveReplacementPromptForSamePane() async {
        let coordinator = TerminalTmuxSessionCoordinator()
        let paneId = UUID()
        let serverId = UUID()
        let staleRequestId = UUID()
        let replacementRequestId = UUID()

        let staleSelection = Task { @MainActor in
            await coordinator.requestSelection(
                requestId: staleRequestId,
                paneId: paneId,
                serverId: serverId,
                availableSessions: []
            )
        }
        guard await waitUntil({
            coordinator.hasPendingPrompt(requestId: staleRequestId)
        }) else {
            Issue.record("Stale tmux prompt was not enqueued")
            staleSelection.cancel()
            return
        }

        let replacementSelection = Task { @MainActor in
            await coordinator.requestSelection(
                requestId: replacementRequestId,
                paneId: paneId,
                serverId: serverId,
                availableSessions: []
            )
        }
        guard await waitUntil({
            coordinator.hasPendingPrompt(requestId: replacementRequestId)
        }) else {
            Issue.record("Replacement tmux prompt was not enqueued")
            staleSelection.cancel()
            replacementSelection.cancel()
            return
        }

        staleSelection.cancel()
        #expect(await waitUntil({
            coordinator.attachPrompt?.id == replacementRequestId
                && !coordinator.hasPendingPrompt(requestId: staleRequestId)
        }))

        coordinator.resolvePrompt(
            requestId: replacementRequestId,
            selection: .createManaged
        )

        #expect(await staleSelection.value == .skipTmux)
        #expect(await replacementSelection.value == .createManaged)
    }

    @Test
    func managedReattachRequiresExplicitSessionConfirmation() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Unconfirmed tmux")
            installTab(tab, in: manager, connectionState: .connected)
            manager.tmuxCoordinator.setAttachment(
                for: tab.rootPaneId,
                sessionName: "vvterm_test",
                ownership: .managed
            )

            #expect(!manager.tmuxCoordinator.shouldReattachManagedSession(for: tab.rootPaneId))

            manager.tmuxCoordinator.confirmManagedSession(for: tab.rootPaneId)

            #expect(manager.tmuxCoordinator.shouldReattachManagedSession(for: tab.rootPaneId))
        }
    }

    @Test
    func managedSessionConfirmationRoundTripsWithoutPromotingUnconfirmedSessions() async {
        await withCleanManager { manager in
            let confirmedTab = TerminalTab(serverId: UUID(), title: "Confirmed tmux")
            let unconfirmedTab = TerminalTab(serverId: UUID(), title: "Unconfirmed tmux")
            installTab(confirmedTab, in: manager, connectionState: .connected)
            installTab(unconfirmedTab, in: manager, connectionState: .connected)

            manager.tmuxCoordinator.setAttachment(
                for: confirmedTab.rootPaneId,
                sessionName: "vvterm_confirmed",
                ownership: .managed,
                managedSessionConfirmed: true
            )
            manager.tmuxCoordinator.setAttachment(
                for: unconfirmedTab.rootPaneId,
                sessionName: "vvterm_unconfirmed",
                ownership: .managed
            )

            manager.persistAndRestoreSnapshotForTesting()

            #expect(manager.tmuxCoordinator.shouldReattachManagedSession(for: confirmedTab.rootPaneId))
            #expect(!manager.tmuxCoordinator.shouldReattachManagedSession(for: unconfirmedTab.rootPaneId))
        }
    }

    @Test
    func managedTmuxCreationFailurePreservesPaneAndClearsUnprovenAttachment() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Failed tmux")
            installTab(tab, in: manager, connectionState: .connected)
            manager.tmuxCoordinator.setAttachment(
                for: tab.rootPaneId,
                sessionName: "vvterm_test",
                ownership: .managed
            )
            manager.tmuxCoordinator.updateStatus(.foreground, for: tab.rootPaneId)

            manager.handleShellEnd(for: tab.rootPaneId, reason: .tmuxCreationFailed)

            #expect(manager.tabs(for: tab.serverId) == [tab])
            #expect(
                manager.paneState(for: tab.rootPaneId)?.connectionState
                    == .failed(String(localized: "Unable to start tmux session."))
            )
            #expect(manager.paneState(for: tab.rootPaneId)?.tmuxStatus == .unknown)
            #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId) == nil)
        }
    }

    @Test
    func successfulTmuxInstallTriggersExplicitReconnect() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Installed tmux")
            installTab(tab, in: manager, connectionState: .connected)
            manager.updatePaneForTesting(tab.rootPaneId) { $0.disconnectReason = .tmuxDetached }
            var reconnectRequested = false

            manager.tmuxCoordinator.completeInstall(
                for: tab.rootPaneId,
                sessionName: "vvterm_installed",
                onInstalled: { reconnectRequested = true }
            )

            #expect(reconnectRequested)
            #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId)?.sessionName == "vvterm_installed")
            #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId)?.ownership == .managed)
        }
    }

    @Test
    func transportEndPreservesPaneAndAllowsAutomaticReconnect() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Dropped transport")
            installTab(tab, in: manager, connectionState: .connected)

            manager.handleShellEnd(for: tab.rootPaneId, reason: .transportEnded)

            #expect(manager.tabs(for: tab.serverId) == [tab])
            #expect(manager.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
            #expect(manager.paneState(for: tab.rootPaneId)?.disconnectReason == .transportEnded)
            #expect(manager.paneState(for: tab.rootPaneId)?.disconnectReason?.allowsAutomaticReconnect == true)
        }
    }

    @Test
    func transientReconnectFailurePreservesAutomaticRetryEligibility() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Transient retry")
            installTab(tab, in: manager, connectionState: .connected)

            manager.handleShellEnd(for: tab.rootPaneId, reason: .transportEnded)
            manager.updatePaneState(
                tab.rootPaneId,
                connectionState: .reconnecting(attempt: 1)
            )
            manager.handleConnectionFailure(for: tab.rootPaneId, error: SSHError.timeout)

            #expect(manager.paneState(for: tab.rootPaneId)?.disconnectReason == .transportEnded)
            guard case .failed = manager.paneState(for: tab.rootPaneId)?.connectionState else {
                Issue.record("Expected a failed retry state")
                return
            }
        }
    }

    @Test
    func unclassifiedReconnectFailurePreservesAutomaticRetryEligibility() async {
        await withCleanManager { manager in
            struct UnclassifiedReconnectError: LocalizedError {
                var errorDescription: String? { "Temporary transport failure" }
            }

            let tab = TerminalTab(serverId: UUID(), title: "Unclassified retry")
            installTab(tab, in: manager, connectionState: .connected)

            manager.handleShellEnd(for: tab.rootPaneId, reason: .transportEnded)
            manager.updatePaneState(
                tab.rootPaneId,
                connectionState: .reconnecting(attempt: 1)
            )
            manager.handleConnectionFailure(
                for: tab.rootPaneId,
                error: UnclassifiedReconnectError()
            )

            #expect(manager.paneState(for: tab.rootPaneId)?.disconnectReason == .transportEnded)
            guard case .failed = manager.paneState(for: tab.rootPaneId)?.connectionState else {
                Issue.record("Expected a failed retry state")
                return
            }
        }
    }

    @Test
    func userActionFailureStopsAutomaticRetry() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Manual recovery")
            installTab(tab, in: manager, connectionState: .connected)

            manager.handleShellEnd(for: tab.rootPaneId, reason: .transportEnded)
            manager.handleConnectionFailure(
                for: tab.rootPaneId,
                error: SSHError.authenticationFailed
            )

            #expect(manager.paneState(for: tab.rootPaneId)?.disconnectReason == nil)
            guard case .failed = manager.paneState(for: tab.rootPaneId)?.connectionState else {
                Issue.record("Expected a failed authentication state")
                return
            }
        }
    }

    @Test
    func staleShellEndCannotDisconnectReplacementShell() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Replacement")
            installTab(tab, in: manager, connectionState: .connected)
            let activeClient = SSHClient()
            let activeShellId = UUID()
            #expect(await startAndRegisterShell(
                activeClient,
                shellId: activeShellId,
                paneId: tab.rootPaneId,
                serverId: tab.serverId,
                in: manager
            ))

            manager.handleShellEnd(
                for: tab.rootPaneId,
                client: SSHClient(),
                shellId: UUID(),
                reason: .transportEnded
            )

            #expect(manager.paneState(for: tab.rootPaneId)?.connectionState == .connected)
            #expect(manager.paneState(for: tab.rootPaneId)?.disconnectReason == nil)
            #expect(manager.activeSSHRoute(for: tab.rootPaneId)?.shellId == activeShellId)
        }
    }

    @Test
    func openingTabSeedsWorkingDirectoryOnlyFromSelectedTabOnSameServer() async throws {
        try await withCleanManager { manager in
            let firstServer = makeServer(name: "First")
            let secondServer = makeServer(name: "Second")

            let firstTab = try await manager.openTab(for: firstServer)
            manager.updatePaneWorkingDirectory(firstTab.rootPaneId, rawDirectory: "/srv/first")

            let otherServerTab = try await manager.openTab(for: secondServer)
            #expect(manager.workingDirectory(for: otherServerTab.rootPaneId) == nil)
            #expect(manager.paneState(for: otherServerTab.rootPaneId)?.seedPaneId == nil)

            let secondFirstServerTab = try await manager.openTab(for: firstServer)
            #expect(manager.workingDirectory(for: secondFirstServerTab.rootPaneId) == "/srv/first")
            #expect(manager.paneState(for: secondFirstServerTab.rootPaneId)?.seedPaneId == firstTab.rootPaneId)
        }
    }

    @Test
    func oscWorkingDirectoryRejectsPercentEncodedCommandControls() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Unsafe PWD")
            installTab(tab, in: manager)

            manager.updatePaneWorkingDirectory(
                tab.rootPaneId,
                rawDirectory: "file://host/C:/safe%0D%0Awhoami"
            )

            #expect(manager.workingDirectory(for: tab.rootPaneId) == nil)
        }
    }

    @Test
    func sharedStatsClientSkipsSelectedMoshTransport() async {
        await withCleanManager { manager in
            let server = makeServer(connectionMode: .mosh)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            installTab(tab, in: manager)

            let client = SSHClient()
            #expect(await startAndRegisterShell(
                client,
                paneId: tab.rootPaneId,
                serverId: server.id,
                transportState: .mosh,
                in: manager
            ))

            #expect(manager.sshClient(for: server.id) === client)
            #expect(manager.sharedStatsClient(for: server.id) == nil)
        }
    }

    @Test
    func splitPaneUsesLatestManagerStateWhenViewTabIsStale() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Split")
            installTab(tab, in: manager)

            guard let firstSplitPane = manager.splitHorizontal(
                tab: tab,
                paneId: tab.rootPaneId,
                hasProAccess: true
            ) else {
                Issue.record("First split failed unexpectedly")
                return
            }

            guard let secondSplitPane = manager.splitVertical(
                tab: tab,
                paneId: firstSplitPane,
                hasProAccess: true
            ) else {
                Issue.record("Second split failed unexpectedly")
                return
            }

            guard let latestTab = manager.tabs(for: tab.serverId).first else {
                Issue.record("Expected tab to exist after split")
                return
            }

            #expect(Set(latestTab.allPaneIds) == [tab.rootPaneId, firstSplitPane, secondSplitPane])
        }
    }

    @Test
    func focusingPaneUsesLatestManagerStateWhenViewTabIsStale() async {
        await withCleanManager { manager in
            let staleTab = TerminalTab(serverId: UUID(), title: "Focus stale tab")
            installTab(staleTab, in: manager, connectionState: .connected)

            guard let firstSplitPane = manager.splitHorizontal(
                tab: staleTab,
                paneId: staleTab.rootPaneId,
                hasProAccess: true
            ), let secondSplitPane = manager.splitVertical(
                tab: staleTab,
                paneId: firstSplitPane,
                hasProAccess: true
            ) else {
                Issue.record("Expected split panes")
                return
            }

            manager.focusPane(in: staleTab, paneId: firstSplitPane)

            guard let currentTab = manager.tabs(for: staleTab.serverId).first else {
                Issue.record("Expected current tab")
                return
            }
            #expect(currentTab.focusedPaneId == firstSplitPane)
            #expect(Set(currentTab.allPaneIds) == [
                staleTab.rootPaneId,
                firstSplitPane,
                secondSplitPane,
            ])
        }
    }

    @Test
    func splitKeyboardCommandsNavigateZoomAndResizeLatestLayout() async {
        await withCleanManager { manager in
            let staleTab = TerminalTab(serverId: UUID(), title: "Keyboard splits")
            installTab(staleTab, in: manager, connectionState: .connected)

            #expect(manager.performSplitCommand(.splitRight, in: staleTab, hasProAccess: true) == .performed)
            #expect(manager.performSplitCommand(.splitDown, in: staleTab, hasProAccess: true) == .performed)

            guard let threePaneTab = manager.tabs(for: staleTab.serverId).first,
                  case .split(let originalRoot) = threePaneTab.layout else {
                Issue.record("Expected three-pane split layout")
                return
            }
            let bottomRightPane = threePaneTab.focusedPaneId

            manager.focusPane(in: staleTab, paneId: staleTab.rootPaneId)
            #expect(!manager.canPerformSplitCommand(.selectAbove, in: staleTab))
            #expect(!manager.canPerformSplitCommand(.selectBelow, in: staleTab))
            #expect(manager.performSplitCommand(.selectAbove, in: staleTab, hasProAccess: true) == .unavailable)
            #expect(manager.performSplitCommand(.selectBelow, in: staleTab, hasProAccess: true) == .unavailable)
            #expect(manager.tabs(for: staleTab.serverId).first?.focusedPaneId == staleTab.rootPaneId)
            manager.focusPane(in: staleTab, paneId: bottomRightPane)

            #expect(manager.performSplitCommand(.selectLeft, in: staleTab, hasProAccess: true) == .performed)
            #expect(manager.tabs(for: staleTab.serverId).first?.focusedPaneId == staleTab.rootPaneId)

            #expect(manager.performSplitCommand(.selectNext, in: staleTab, hasProAccess: true) == .performed)
            let nextPane = manager.tabs(for: staleTab.serverId).first?.focusedPaneId
            #expect(nextPane != nil)
            #expect(nextPane != staleTab.rootPaneId)

            #expect(manager.performSplitCommand(.toggleZoom, in: staleTab, hasProAccess: true) == .performed)
            #expect(manager.isSplitZoomed(in: threePaneTab))
            #expect(manager.performSplitCommand(.selectNext, in: staleTab, hasProAccess: true) == .performed)
            #expect(manager.isSplitZoomed(in: threePaneTab))

            #expect(manager.performSplitCommand(.moveDividerLeft, in: staleTab, hasProAccess: true) == .performed)
            guard let resizedTab = manager.tabs(for: staleTab.serverId).first,
                  case .split(let resizedRoot) = resizedTab.layout else {
                Issue.record("Expected resized split layout")
                return
            }
            #expect(resizedRoot.ratio < originalRoot.ratio)

            #expect(manager.performSplitCommand(.equalize, in: staleTab, hasProAccess: true) == .performed)
            #expect(manager.performSplitCommand(.closeFocusedPane, in: staleTab, hasProAccess: true) == .requiresCloseConfirmation)
            #expect(manager.tabs(for: staleTab.serverId).first?.paneCount == 3)

            #expect(manager.performSplitCommand(.toggleZoom, in: staleTab, hasProAccess: true) == .performed)
            #expect(!manager.isSplitZoomed(in: threePaneTab))
        }
    }

    @Test
    func splitCreationCommandReportsUpgradeRequirement() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Free split")
            installTab(tab, in: manager, connectionState: .connected)

            #expect(manager.performSplitCommand(.splitRight, in: tab, hasProAccess: false) == .requiresUpgrade)
            #expect(manager.tabs(for: tab.serverId).first?.paneCount == 1)
        }
    }

    @Test
    func closingSplitPaneKeepsSiblingConnected() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Close split")
            installTab(tab, in: manager, connectionState: .connected)
            guard let splitPane = manager.splitHorizontal(
                tab: tab,
                paneId: tab.rootPaneId,
                hasProAccess: true
            ) else {
                Issue.record("Expected split pane")
                return
            }
            manager.updatePaneState(splitPane, connectionState: .connected)

            manager.closePane(tab: tab, paneId: splitPane)

            #expect(manager.paneState(for: splitPane) == nil)
            #expect(manager.paneState(for: tab.rootPaneId)?.connectionState == .connected)
            #expect(manager.paneState(for: tab.rootPaneId)?.disconnectReason == nil)
            #expect(manager.tabs(for: tab.serverId).first?.allPaneIds == [tab.rootPaneId])
        }
    }

    @Test
    func closeTabUsesLatestManagerStateWhenViewTabIsStale() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Close stale tab")
            installTab(tab, in: manager, connectionState: .connected)

            guard let splitPane = manager.splitHorizontal(
                tab: tab,
                paneId: tab.rootPaneId,
                hasProAccess: true
            ) else {
                Issue.record("Split failed unexpectedly")
                return
            }
            manager.updatePaneState(splitPane, connectionState: .connected)

            #expect(
                TerminalLiveActivityPolicy.snapshot(
                    for: manager.allPaneStatesForTesting.map(\.connectionState)
                )?.activeCount == 2
            )

            manager.closeTab(tab)

            #expect(manager.tabs(for: tab.serverId).isEmpty)
            #expect(manager.allPaneStatesForTesting.isEmpty)
            #expect(
                TerminalLiveActivityPolicy.snapshot(
                    for: manager.allPaneStatesForTesting.map(\.connectionState)
                ) == nil
            )
        }
    }

    #if os(iOS)
    @Test
    func applicationTerminationPreservesTabsAndCompletesActivityCleanup() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Termination")
            installTab(tab, in: manager, connectionState: .connected)

            let appDelegate = AppDelegate()
            let appLockManager = AppLockManager()
            let serverManager = ServerManager(
                dependencies: .live(
                    actionAuthorizer: appLockManager,
                    syncRepository: CloudKitSyncLiveComposition.makeLiveCoordinator()
                ),
                startsAutomatically: false
            )
            appDelegate.configure(
                tabManager: manager,
                serverManager: serverManager,
                appLockManager: appLockManager,
                lifecycleDependencies: AppLifecycleDependencies(
                    subscribeToRemoteChanges: {},
                    refreshNetwork: {},
                    endLiveActivitiesForApplicationTermination: { true }
                )
            )
            #expect(appDelegate.handleApplicationWillTerminate())

            #expect(manager.tabs(for: tab.serverId).map(\.id) == [tab.id])
            #expect(manager.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
            #expect(manager.paneState(for: tab.rootPaneId)?.disconnectReason == .transportEnded)
            #expect(manager.connectedServerIds.isEmpty)
        }
    }
    #endif
}

struct TerminalTeardownIntentTests {
    @Test
    func onlyApplicationTerminationPreservesReconnectableDescriptorsAndETCredentials() {
        for intent in TerminalTeardownIntent.allCases {
            let preservesReconnectableState = intent == .applicationTermination
            #expect(intent.removesPersistedDescriptor != preservesReconnectableState)
            #expect(intent.deletesResumableSessionState != preservesReconnectableState)
        }
    }

    @Test
    func onlyExplicitUserActionsTerminateManagedTmux() {
        #expect(TerminalTeardownIntent.explicitClose.terminatesManagedTmux)
        #expect(TerminalTeardownIntent.explicitServerDisconnect.terminatesManagedTmux)
        #expect(!TerminalTeardownIntent.remoteSessionEnded.terminatesManagedTmux)
        #expect(!TerminalTeardownIntent.applicationTermination.terminatesManagedTmux)
    }
}
