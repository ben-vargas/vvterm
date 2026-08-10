import Foundation
import Combine
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
            manager.sessionState.updatePane(tab.rootPaneId) {
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

            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.activeTransport == .sshFallback)
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.moshFallbackReason == .udpTimeout)
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.moshFallbackDiagnostics == nil)

            manager.updatePaneState(tab.rootPaneId, connectionState: .reconnecting(attempt: 1))
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.activeTransport == .ssh)
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.moshFallbackReason == nil)
        }
    }

    @Test
    func reconnectGenerationCreatesExactlyOneManagerOwnedReplacement() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Wake recovery")
            installTab(tab, in: manager, connectionState: .connected)
            manager.updatePaneState(tab.rootPaneId, connectionState: .disconnected)
            manager.reconnectCoordinator.receiveApplicationActivity(true)
            let originalTerminalGeneration = manager.reconnectCoordinator.connectionGeneration(
                for: tab.rootPaneId
            )
            let recoveryGeneration = UUID()

            #expect(manager.reconnectCoordinator.request(
                for: tab.rootPaneId,
                requiresReadyNetwork: false,
                generation: recoveryGeneration,
                replacingCurrent: true
            ))
            #expect(!manager.reconnectCoordinator.request(
                for: tab.rootPaneId,
                requiresReadyNetwork: false,
                generation: recoveryGeneration,
                replacingCurrent: true
            ))
            #expect(await waitUntil {
                manager.reconnectCoordinator.attempt(for: tab.rootPaneId)?.phase == .connecting
            })
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState.isConnecting == true)
            #expect(
                manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
                    != originalTerminalGeneration
            )

            manager.updatePaneState(tab.rootPaneId, connectionState: .connected)
            #expect(manager.reconnectCoordinator.attempt(for: tab.rootPaneId) == nil)
        }
    }

    #if os(iOS)
    @Test
    func offlineReconnectWaitsWithoutStartingThenStartsExactlyOnceWhenReady() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Offline recovery")
            installTab(tab, in: manager, connectionState: .connected)
            manager.updatePaneState(tab.rootPaneId, connectionState: .disconnected)
            let originalTerminalGeneration = manager.reconnectCoordinator.connectionGeneration(
                for: tab.rootPaneId
            )
            manager.reconnectCoordinator.receiveNetworkReadiness(.unavailable)

            #expect(manager.reconnectCoordinator.request(
                for: tab.rootPaneId,
                requiresReadyNetwork: false,
                generation: UUID(),
                replacingCurrent: false
            ))
            #expect(!manager.reconnectCoordinator.request(
                for: tab.rootPaneId,
                requiresReadyNetwork: false,
                generation: UUID(),
                replacingCurrent: false
            ))
            #expect(await waitUntil {
                manager.reconnectCoordinator.attempt(for: tab.rootPaneId)?.phase == .waitingForNetwork
            })
            #expect(
                manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
                    == originalTerminalGeneration
            )
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)

            manager.reconnectCoordinator.receiveNetworkReadiness(.ready)
            #expect(await waitUntil {
                manager.reconnectCoordinator.attempt(for: tab.rootPaneId)?.phase == .connecting
            })
            let replacementGeneration = manager.reconnectCoordinator.connectionGeneration(
                for: tab.rootPaneId
            )
            #expect(replacementGeneration != originalTerminalGeneration)

            manager.reconnectCoordinator.receiveNetworkReadiness(.ready)
            await Task.yield()
            #expect(
                manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
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
            let originalTerminalGeneration = manager.reconnectCoordinator.connectionGeneration(
                for: tab.rootPaneId
            )
            manager.reconnectCoordinator.receiveNetworkReadiness(.ready)

            #expect(manager.reconnectCoordinator.request(
                for: tab.rootPaneId,
                requiresReadyNetwork: false,
                generation: UUID(),
                replacingCurrent: true
            ))
            manager.reconnectCoordinator.receiveNetworkReadiness(.unavailable)

            #expect(await waitUntil {
                manager.reconnectCoordinator.attempt(for: tab.rootPaneId)?.phase == .waitingForNetwork
            })
            #expect(
                manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
                    == originalTerminalGeneration
            )

            manager.reconnectCoordinator.receiveNetworkReadiness(.ready)
            #expect(await waitUntil {
                manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
                    != originalTerminalGeneration
            })
            let replacementGeneration = manager.reconnectCoordinator.connectionGeneration(
                for: tab.rootPaneId
            )
            manager.reconnectCoordinator.receiveNetworkReadiness(.ready)
            await Task.yield()
            #expect(
                manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
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
            let oldRuntime = manager.transportCoordinator.eternalTerminalRuntime(
                for: tab.rootPaneId,
                server: server,
                credentials: credentials
            )

            #expect(manager.reconnectCoordinator.request(
                for: tab.rootPaneId,
                requiresReadyNetwork: false,
                generation: UUID(),
                replacingCurrent: true
            ))
            #expect(await waitUntil {
                !manager.transportCoordinator.isCurrentEternalTerminalRuntime(oldRuntime, for: tab.rootPaneId)
            })

            let replacement = manager.transportCoordinator.eternalTerminalRuntime(
                for: tab.rootPaneId,
                server: server,
                credentials: credentials
            )
            await manager.transportCoordinator.unregisterEternalTerminalRuntime(
                for: tab.rootPaneId,
                ifOwnedBy: oldRuntime
            )
            #expect(manager.transportCoordinator.isCurrentEternalTerminalRuntime(replacement, for: tab.rootPaneId))
        }
    }

    #if os(macOS)
    @Test
    func macWakeSignalsCreateExactlyOneManagerOwnedReplacement() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Mac wake recovery")
            installTab(tab, in: manager, connectionState: .connected)
            let originalTerminalGeneration = manager.reconnectCoordinator.connectionGeneration(
                for: tab.rootPaneId
            )
            #expect(await waitUntil { NetworkMonitor.shared.readiness == .ready })

            manager.reconnectCoordinator.receiveMacRecoverySignal(.sleep)
            manager.reconnectCoordinator.receiveMacRecoverySignal(.wake)
            manager.reconnectCoordinator.receiveMacRecoverySignal(.applicationActivated)
            manager.reconnectCoordinator.receiveMacRecoverySignal(.networkChanged(.ready))

            #expect(await waitUntil {
                manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
                    != originalTerminalGeneration
            })
            let replacementGeneration = manager.reconnectCoordinator.connectionGeneration(
                for: tab.rootPaneId
            )

            manager.reconnectCoordinator.receiveMacRecoverySignal(.wake)
            manager.reconnectCoordinator.receiveMacRecoverySignal(.applicationActivated)
            await Task.yield()
            #expect(
                manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
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
            let originalTerminalGeneration = manager.reconnectCoordinator.connectionGeneration(
                for: tab.rootPaneId
            )

            manager.reconnectCoordinator.receiveNetworkReadiness(.ready)
            let recoveryGeneration = UUID()

            #expect(manager.reconnectCoordinator.request(
                for: tab.rootPaneId,
                requiresReadyNetwork: true,
                generation: recoveryGeneration,
                replacingCurrent: true
            ))
            manager.reconnectCoordinator.receiveNetworkReadiness(.unavailable)

            #expect(await waitUntil {
                manager.reconnectCoordinator.attempt(for: tab.rootPaneId)?.phase == .waitingForNetwork
            })
            #expect(
                manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
                    == originalTerminalGeneration
            )

            manager.reconnectCoordinator.receiveNetworkReadiness(.ready)
            #expect(await waitUntil {
                manager.reconnectCoordinator.connectionGeneration(for: tab.rootPaneId)
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
            manager.sessionState.setPaneState(TerminalPaneState(
                paneId: siblingPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            ))

            let result = manager.handleTerminalZoom(.zoomIn, for: tab.rootPaneId)

            #expect(result?.effectiveFontSize == 13.0)
            #expect(manager.sessionState.presentationOverrides(for: tab.rootPaneId).fontSize == 13.0)
            #expect(manager.sessionState.presentationOverrides(for: siblingPaneId).isEmpty)
            #expect(defaults.double(forKey: TerminalDefaults.fontSizeKey) == 12.0)
        }
    }

    @Test
    func successfulMoshRegistrationReplacesFallbackDiagnostics() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Mosh recovery")
            installTab(tab, in: manager, connectionState: .connected)
            manager.sessionState.updatePane(tab.rootPaneId) {
                $0.transportState = .sshFallback(
                    reason: .udpTimeout,
                    diagnostics: .make(
                    reason: .udpTimeout,
                    events: [],
                    appContext: .init(version: "test", platform: "test")
                    )
                )
            }

            let client = SSHClient.testing()
            #expect(await startAndRegisterShell(
                client,
                paneId: tab.rootPaneId,
                serverId: tab.serverId,
                transportState: .mosh,
                in: manager
            ))
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.activeTransport == .mosh)
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.moshFallbackReason == nil)
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.moshFallbackDiagnostics == nil)
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

    @Test
    func toolbarProjectionSeparatesMenuTabTitleAndVoiceInvalidation() async {
        await withCleanManager { manager in
            let observedTab = TerminalTab(serverId: UUID(), title: "Observed")
            let otherTab = TerminalTab(serverId: UUID(), title: "Other")
            installTab(observedTab, in: manager, connectionState: .connected)
            installTab(otherTab, in: manager, connectionState: .connected)
            let projection = TerminalServerToolbarProjection(
                serverId: observedTab.serverId,
                tabManager: manager
            )
            var contentUpdates = 0
            var menuUpdates = 0
            var tabStripUpdates = 0
            #if os(iOS)
            var floatingControlUpdates = 0
            #endif
            var routeUpdates = 0
            var cancellations = [
                projection.objectWillChange.sink { routeUpdates += 1 },
                projection.content.objectWillChange.sink { contentUpdates += 1 },
                projection.menu.objectWillChange.sink { menuUpdates += 1 },
                projection.tabStrip.objectWillChange.sink { tabStripUpdates += 1 }
            ]
            #if os(iOS)
            cancellations.append(
                projection.floatingControls.objectWillChange.sink { floatingControlUpdates += 1 }
            )
            #endif
            defer {
                cancellations.forEach { $0.cancel() }
            }

            manager.updatePaneWorkingDirectory(
                observedTab.rootPaneId,
                rawDirectory: "/tmp/output-metadata"
            )
            #expect(contentUpdates == 0)
            #expect(menuUpdates == 0)
            #expect(tabStripUpdates == 0)
            #if os(iOS)
            #expect(floatingControlUpdates == 0)
            #endif
            #expect(routeUpdates == 0)

            manager.updatePaneTitle(observedTab.rootPaneId, rawTitle: "Output title")
            #expect(contentUpdates == 0)
            #expect(menuUpdates == 0)
            #expect(tabStripUpdates == 1)
            #if os(iOS)
            #expect(floatingControlUpdates == 0)
            #endif
            #expect(routeUpdates == 0)

            #if os(iOS)
            manager.presentationState.applyVoiceEvent(.recordingStarted, for: otherTab.rootPaneId)
            #expect(floatingControlUpdates == 0)
            #expect(routeUpdates == 0)

            manager.presentationState.applyVoiceEvent(.recordingStarted, for: observedTab.rootPaneId)
            #expect(floatingControlUpdates == 1)
            #expect(routeUpdates == 1)
            #expect(manager.presentationState.voicePresentation(for: observedTab.rootPaneId) == .recording)

            manager.presentationState.applyVoiceEvent(.transcriptionSent, for: observedTab.rootPaneId)
            #expect(floatingControlUpdates == 2)
            #expect(routeUpdates == 2)
            #expect(manager.presentationState.voicePresentation(for: observedTab.rootPaneId) == .pendingReturn)
            #endif
        }
    }

    private func installTab(
        _ tab: TerminalTab,
        in manager: TerminalTabManager,
        connectionState: ConnectionState = .connecting
    ) {
        manager.sessionState.install(tab, paneState: TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        ), select: true)
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
        guard let startToken = manager.transportCoordinator.beginShellStart(for: paneId, client: client) else {
            return false
        }
        return await manager.transportCoordinator.registerSSHClient(
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
            let oldClient = SSHClient.testing()
            let oldShellId = UUID()

            #expect(await startAndRegisterShell(
                oldClient,
                shellId: oldShellId,
                paneId: tab.rootPaneId,
                serverId: tab.serverId,
                in: manager
            ))
            await manager.transportCoordinator.unregisterSSHClient(for: tab.rootPaneId)

            let replacementClient = SSHClient.testing()
            let replacementShellId = UUID()
            #expect(await startAndRegisterShell(
                replacementClient,
                shellId: replacementShellId,
                paneId: tab.rootPaneId,
                serverId: tab.serverId,
                in: manager
            ))

            await manager.transportCoordinator.unregisterSSHClient(
                for: tab.rootPaneId,
                ifOwnedBy: oldClient,
                shellId: oldShellId
            )

            #expect(manager.transportCoordinator.activeSSHRoute(for: tab.rootPaneId)?.shellId == replacementShellId)
            #expect(manager.transportCoordinator.activeSSHRoute(for: tab.rootPaneId)?.client === replacementClient)
        }
    }

    @Test
    func currentSurfaceExitCancelsPendingStartWithoutRemovingReplacement() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Pending surface exit")
            installTab(tab, in: manager)
            let exitedSurfaceClient = SSHClient.testing()

            guard let exitedStartToken = manager.transportCoordinator.beginShellStart(
                for: tab.rootPaneId,
                client: exitedSurfaceClient
            ), let exitedConnectionToken = manager.transportCoordinator.connectionOwnershipToken(for: tab.rootPaneId) else {
                Issue.record("Expected the exiting surface to own a shell start")
                return
            }
            #expect(exitedConnectionToken == exitedStartToken)
            #expect(manager.transportCoordinator.isCurrentShellOwner(
                for: tab.rootPaneId,
                client: exitedSurfaceClient,
                startToken: exitedStartToken
            ))

            await manager.transportCoordinator.unregisterSSHClient(
                for: tab.rootPaneId,
                ifOwnedBy: exitedConnectionToken
            )
            #expect(!manager.transportCoordinator.isTransportStartInFlight(for: tab.rootPaneId))

            guard let replacementStartToken = manager.transportCoordinator.beginShellStart(
                for: tab.rootPaneId,
                client: exitedSurfaceClient
            ) else {
                Issue.record("Expected a same-client replacement shell start")
                return
            }

            await manager.transportCoordinator.unregisterSSHClient(
                for: tab.rootPaneId,
                ifOwnedBy: exitedConnectionToken
            )
            #expect(manager.transportCoordinator.isTransportStartInFlight(for: tab.rootPaneId))
            #expect(manager.transportCoordinator.isCurrentShellOwner(
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

            let activeClient = SSHClient.testing()
            let staleClient = SSHClient.testing()
            guard let activeStartToken = manager.transportCoordinator.beginShellStart(
                for: tab.rootPaneId,
                client: activeClient
            ) else {
                Issue.record("Expected active shell start")
                return
            }

            #expect(!(await manager.transportCoordinator.registerSSHClient(
                staleClient,
                shellId: UUID(),
                startToken: activeStartToken,
                for: tab.rootPaneId,
                serverId: serverId
            )))

            #expect(manager.transportCoordinator.activeSSHRoute(for: tab.rootPaneId) == nil)
            #expect(manager.transportCoordinator.isTransportStartInFlight(for: tab.rootPaneId))

            manager.transportCoordinator.finishShellStart(
                for: tab.rootPaneId,
                client: staleClient,
                startToken: activeStartToken
            )
            #expect(manager.transportCoordinator.isTransportStartInFlight(for: tab.rootPaneId))

            manager.transportCoordinator.finishShellStart(
                for: tab.rootPaneId,
                client: activeClient,
                startToken: activeStartToken
            )
            #expect(!manager.transportCoordinator.isTransportStartInFlight(for: tab.rootPaneId))
        }
    }

    @Test
    func unregisterWithoutShellClearsPendingStart() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Pending")
            installTab(tab, in: manager)

            let firstClient = SSHClient.testing()
            #expect(manager.transportCoordinator.beginShellStart(for: tab.rootPaneId, client: firstClient) != nil)

            await manager.transportCoordinator.unregisterSSHClient(for: tab.rootPaneId)

            #expect(!manager.transportCoordinator.isTransportStartInFlight(for: tab.rootPaneId))
            #expect(manager.transportCoordinator.activeSSHRoute(for: tab.rootPaneId) == nil)

            let nextClient = SSHClient.testing()
            guard let nextStartToken = manager.transportCoordinator.beginShellStart(
                for: tab.rootPaneId,
                client: nextClient
            ) else {
                Issue.record("Expected replacement shell start")
                return
            }
            manager.transportCoordinator.finishShellStart(
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
            let client = SSHClient.testing()
            guard let startToken = manager.transportCoordinator.beginShellStart(
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

            await manager.transportCoordinator.unregisterSSHClient(for: tab.rootPaneId)

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
            let activeClient = SSHClient.testing()
            let staleClient = SSHClient.testing()

            guard let activeStartToken = manager.transportCoordinator.beginShellStart(
                for: tab.rootPaneId,
                client: activeClient
            ) else {
                Issue.record("Expected active shell start")
                return
            }
            #expect(manager.transportCoordinator.isCurrentShellOwner(
                for: tab.rootPaneId,
                client: activeClient,
                startToken: activeStartToken
            ))
            #expect(!manager.transportCoordinator.isCurrentShellOwner(
                for: tab.rootPaneId,
                client: staleClient,
                startToken: activeStartToken
            ))

            await manager.transportCoordinator.unregisterSSHClient(for: tab.rootPaneId)

            #expect(!manager.transportCoordinator.isCurrentShellOwner(
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

            #expect(manager.transportCoordinator.beginShellStart(for: missingPaneId, client: SSHClient.testing()) == nil)
            #expect(!manager.transportCoordinator.isTransportStartInFlight(for: missingPaneId))
        }
    }

    @Test
    func disconnectServerLeavesOtherServerTabsAndShellsConnected() async {
        await withCleanManager { manager in
            let firstTab = TerminalTab(serverId: UUID(), title: "First")
            let secondTab = TerminalTab(serverId: UUID(), title: "Second")
            installTab(firstTab, in: manager)
            installTab(secondTab, in: manager)

            let firstClient = SSHClient.testing()
            let secondClient = SSHClient.testing()
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

            #expect(manager.sessionState.tabs(for: firstTab.serverId).isEmpty)
            #expect(manager.sessionState.paneState(for: firstTab.rootPaneId) == nil)
            #expect(manager.transportCoordinator.activeSSHRoute(for: firstTab.rootPaneId) == nil)
            #expect(manager.sessionState.tabs(for: secondTab.serverId) == [secondTab])
            #expect(manager.sessionState.paneState(for: secondTab.rootPaneId)?.connectionState == .connected)
            #expect(manager.transportCoordinator.activeSSHRoute(for: secondTab.rootPaneId) != nil)
        }
    }

    @Test
    func staleShellOnSharedClientDoesNotDisconnectSiblingPane() async {
        await withCleanManager { manager in
            let siblingTab = TerminalTab(serverId: UUID(), title: "Sibling")
            let pendingTab = TerminalTab(serverId: UUID(), title: "Pending")
            installTab(siblingTab, in: manager)
            installTab(pendingTab, in: manager)

            let sharedClient = SSHClient.testing()
            #expect(await startAndRegisterShell(
                sharedClient,
                paneId: siblingTab.rootPaneId,
                serverId: siblingTab.serverId,
                in: manager
            ))

            let pendingClient = SSHClient.testing()
            guard let pendingStartToken = manager.transportCoordinator.beginShellStart(
                for: pendingTab.rootPaneId,
                client: pendingClient
            ) else {
                Issue.record("Expected pending shell start")
                return
            }
            #expect(!(await manager.transportCoordinator.registerSSHClient(
                sharedClient,
                shellId: UUID(),
                startToken: pendingStartToken,
                for: pendingTab.rootPaneId,
                serverId: pendingTab.serverId
            )))

            #expect(!(await sharedClient.isAborted))
            #expect(manager.transportCoordinator.activeSSHRoute(for: siblingTab.rootPaneId)?.client === sharedClient)
            #expect(manager.transportCoordinator.isCurrentShellOwner(
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

            let client = SSHClient.testing()
            #expect(await startAndRegisterShell(
                client,
                paneId: tab.rootPaneId,
                serverId: tab.serverId,
                in: manager
            ))
            manager.updatePaneState(tab.rootPaneId, connectionState: .connected)

            manager.updatePaneState(tab.rootPaneId, connectionState: .disconnected)
            await manager.transportCoordinator.unregisterSSHClient(for: tab.rootPaneId)

            #expect(manager.sessionState.tabs(for: tab.serverId) == [tab])
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
            #expect(manager.transportCoordinator.activeSSHRoute(for: tab.rootPaneId) == nil)
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

            #expect(manager.sessionState.tabs(for: tab.serverId).isEmpty)
            #expect(manager.sessionState.paneState(for: tab.rootPaneId) == nil)
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
            manager.sessionState.setPaneState(TerminalPaneState(
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

            let remainingTab = manager.sessionState.tabs(for: tab.serverId).first
            #expect(remainingTab?.allPaneIds == [tab.rootPaneId])
            #expect(manager.sessionState.paneState(for: tab.rootPaneId) != nil)
            #expect(manager.sessionState.paneState(for: secondPaneId) == nil)
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

            #expect(manager.sessionState.tabs(for: tab.serverId) == [tab])
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == .tmuxDetached)
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason?.allowsAutomaticReconnect == false)
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

                let disconnectedClient = SSHClient.testing()
                guard let startToken = manager.transportCoordinator.beginShellStart(
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

                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.tmuxStatus == .background)
                #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId) == TerminalTmuxAttachmentState(
                    sessionName: "vvterm_existing",
                    ownership: .managed,
                    managedSessionConfirmed: true
                ))
                #expect(manager.tmuxCoordinator.attachPrompt == nil)

                manager.transportCoordinator.finishShellStart(
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

                let client = SSHClient.testing()
                guard let startToken = manager.transportCoordinator.beginShellStart(
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

                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.tmuxStatus == .missing)
                #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId) == nil)

                manager.transportCoordinator.finishShellStart(
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

                let client = SSHClient.testing()
                let gate = TmuxAvailabilityGate()
                guard let staleStartToken = manager.transportCoordinator.beginShellStart(
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
                manager.transportCoordinator.finishShellStart(
                    for: tab.rootPaneId,
                    client: client,
                    startToken: staleStartToken
                )
                guard let replacementStartToken = manager.transportCoordinator.beginShellStart(
                    for: tab.rootPaneId,
                    client: client
                ) else {
                    Issue.record("Expected replacement shell start")
                    return
                }
                await gate.resolve(.confirmedMissing)

                #expect(await stalePlan.value)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.tmuxStatus == .background)
                #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId) == TerminalTmuxAttachmentState(
                    sessionName: "vvterm_existing",
                    ownership: .managed,
                    managedSessionConfirmed: true
                ))

                manager.transportCoordinator.finishShellStart(
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

                let client = SSHClient.testing()
                let gate = TmuxAvailabilityGate()
                guard let startToken = manager.transportCoordinator.beginShellStart(
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
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.tmuxStatus == .background)
                #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId) == TerminalTmuxAttachmentState(
                    sessionName: "vvterm_existing",
                    ownership: .managed,
                    managedSessionConfirmed: true
                ))

                manager.transportCoordinator.finishShellStart(
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

            manager.sessionState.persistAndRestoreSnapshotForTesting()

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

            #expect(manager.sessionState.tabs(for: tab.serverId) == [tab])
            #expect(
                manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState
                    == .failed(.tmuxStartupFailed)
            )
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.tmuxStatus == .unknown)
            #expect(manager.tmuxCoordinator.attachment(for: tab.rootPaneId) == nil)
        }
    }

    @Test
    func successfulTmuxInstallTriggersExplicitReconnect() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Installed tmux")
            installTab(tab, in: manager, connectionState: .connected)
            manager.sessionState.updatePane(tab.rootPaneId) { $0.disconnectReason = .tmuxDetached }
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

            #expect(manager.sessionState.tabs(for: tab.serverId) == [tab])
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == .transportEnded)
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason?.allowsAutomaticReconnect == true)
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
            manager.handleConnectionFailure(
                for: tab.rootPaneId,
                failure: .transport(SSHError.timeout)
            )

            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == .transportEnded)
            guard case .failed = manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState else {
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
                failure: .transport(UnclassifiedReconnectError())
            )

            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == .transportEnded)
            guard case .failed = manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState else {
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
                failure: .transport(SSHError.authenticationFailed)
            )

            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == nil)
            guard case .failed = manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState else {
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
            let activeClient = SSHClient.testing()
            let activeShellId = UUID()
            #expect(await startAndRegisterShell(
                activeClient,
                shellId: activeShellId,
                paneId: tab.rootPaneId,
                serverId: tab.serverId,
                in: manager
            ))

            manager.transportCoordinator.handleShellEnd(
                for: tab.rootPaneId,
                client: SSHClient.testing(),
                shellId: UUID(),
                reason: .transportEnded
            )

            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .connected)
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == nil)
            #expect(manager.transportCoordinator.activeSSHRoute(for: tab.rootPaneId)?.shellId == activeShellId)
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
            #expect(manager.sessionState.paneState(for: otherServerTab.rootPaneId)?.workingDirectory == nil)
            #expect(manager.sessionState.paneState(for: otherServerTab.rootPaneId)?.seedPaneId == nil)

            let secondFirstServerTab = try await manager.openTab(for: firstServer)
            #expect(
                manager.sessionState.paneState(for: secondFirstServerTab.rootPaneId)?.workingDirectory
                    == "/srv/first"
            )
            #expect(manager.sessionState.paneState(for: secondFirstServerTab.rootPaneId)?.seedPaneId == firstTab.rootPaneId)
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

            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.workingDirectory == nil)
        }
    }

    @Test
    func sharedStatsClientSkipsSelectedMoshTransport() async {
        await withCleanManager { manager in
            let server = makeServer(connectionMode: .mosh)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            installTab(tab, in: manager)

            let client = SSHClient.testing()
            #expect(await startAndRegisterShell(
                client,
                paneId: tab.rootPaneId,
                serverId: server.id,
                transportState: .mosh,
                in: manager
            ))

            #expect(manager.transportCoordinator.sshClient(for: server.id) === client)
            #expect(manager.transportCoordinator.sharedStatsClient(for: server.id) == nil)
        }
    }

    @Test
    func splitPaneUsesLatestManagerStateWhenViewTabIsStale() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Split")
            installTab(tab, in: manager)

            guard let firstSplitPane = manager.splitRight(
                tab: tab,
                paneId: tab.rootPaneId,
                hasProAccess: true
            ) else {
                Issue.record("First split failed unexpectedly")
                return
            }

            guard let secondSplitPane = manager.splitDown(
                tab: tab,
                paneId: firstSplitPane,
                hasProAccess: true
            ) else {
                Issue.record("Second split failed unexpectedly")
                return
            }

            guard let latestTab = manager.sessionState.tabs(for: tab.serverId).first else {
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

            guard let firstSplitPane = manager.splitRight(
                tab: staleTab,
                paneId: staleTab.rootPaneId,
                hasProAccess: true
            ), let secondSplitPane = manager.splitDown(
                tab: staleTab,
                paneId: firstSplitPane,
                hasProAccess: true
            ) else {
                Issue.record("Expected split panes")
                return
            }

            manager.focusPane(in: staleTab, paneId: firstSplitPane)

            guard let currentTab = manager.sessionState.tabs(for: staleTab.serverId).first else {
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

            guard let threePaneTab = manager.sessionState.tabs(for: staleTab.serverId).first,
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
            #expect(manager.sessionState.tabs(for: staleTab.serverId).first?.focusedPaneId == staleTab.rootPaneId)
            manager.focusPane(in: staleTab, paneId: bottomRightPane)

            #expect(manager.performSplitCommand(.selectLeft, in: staleTab, hasProAccess: true) == .performed)
            #expect(manager.sessionState.tabs(for: staleTab.serverId).first?.focusedPaneId == staleTab.rootPaneId)

            #expect(manager.performSplitCommand(.selectNext, in: staleTab, hasProAccess: true) == .performed)
            let nextPane = manager.sessionState.tabs(for: staleTab.serverId).first?.focusedPaneId
            #expect(nextPane != nil)
            #expect(nextPane != staleTab.rootPaneId)

            #expect(manager.performSplitCommand(.toggleZoom, in: staleTab, hasProAccess: true) == .performed)
            #expect(manager.isSplitZoomed(in: threePaneTab))
            #expect(manager.performSplitCommand(.selectNext, in: staleTab, hasProAccess: true) == .performed)
            #expect(manager.isSplitZoomed(in: threePaneTab))

            #expect(manager.performSplitCommand(.moveDividerLeft, in: staleTab, hasProAccess: true) == .performed)
            guard let resizedTab = manager.sessionState.tabs(for: staleTab.serverId).first,
                  case .split(let resizedRoot) = resizedTab.layout else {
                Issue.record("Expected resized split layout")
                return
            }
            #expect(resizedRoot.ratio < originalRoot.ratio)

            #expect(manager.performSplitCommand(.equalize, in: staleTab, hasProAccess: true) == .performed)
            #expect(manager.performSplitCommand(.closeFocusedPane, in: staleTab, hasProAccess: true) == .requiresCloseConfirmation)
            #expect(manager.sessionState.tabs(for: staleTab.serverId).first?.paneCount == 3)

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
            #expect(manager.sessionState.tabs(for: tab.serverId).first?.paneCount == 1)
        }
    }

    @Test
    func closingSplitPaneKeepsSiblingConnected() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Close split")
            installTab(tab, in: manager, connectionState: .connected)
            guard let splitPane = manager.splitRight(
                tab: tab,
                paneId: tab.rootPaneId,
                hasProAccess: true
            ) else {
                Issue.record("Expected split pane")
                return
            }
            manager.updatePaneState(splitPane, connectionState: .connected)

            manager.closePane(tab: tab, paneId: splitPane)

            #expect(manager.sessionState.paneState(for: splitPane) == nil)
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .connected)
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == nil)
            #expect(manager.sessionState.tabs(for: tab.serverId).first?.allPaneIds == [tab.rootPaneId])
        }
    }

    @Test
    func closeTabUsesLatestManagerStateWhenViewTabIsStale() async {
        await withCleanManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Close stale tab")
            installTab(tab, in: manager, connectionState: .connected)

            guard let splitPane = manager.splitRight(
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
                    for: manager.sessionState.allPaneStates.map(\.connectionState)
                )?.activeCount == 2
            )

            manager.closeTab(tab)

            #expect(manager.sessionState.tabs(for: tab.serverId).isEmpty)
            #expect(manager.sessionState.allPaneStates.isEmpty)
            #expect(
                TerminalLiveActivityPolicy.snapshot(
                    for: manager.sessionState.allPaneStates.map(\.connectionState)
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
            let defaults = UserDefaults.standard
            let cloudKitSync = CloudKitSyncLiveComposition.makeLive(
                transport: CloudKitManager.shared,
                defaults: defaults,
                now: Date.init,
                makeID: UUID.init
            )
            let serverManager = ServerManager(
                dependencies: .live(
                    defaults: defaults,
                    serverCloud: cloudKitSync.serverCloud,
                    credentialRepository: KeychainManager.shared,
                    knownHosts: KnownHostsManager.shared,
                    freePlanTracker: AnalyticsTracker.shared,
                    actionAuthorizer: appLockManager,
                    syncRepository: cloudKitSync.coordinator,
                    defaultWorkspaceName: { "Default" },
                    canonicalDefaultWorkspaceNames: { ["Default"] },
                    now: Date.init,
                    makeID: UUID.init
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

            #expect(manager.sessionState.tabs(for: tab.serverId).map(\.id) == [tab.id])
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
            #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == .transportEnded)
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
