import Foundation
import Combine
import Testing
@testable import VVTerm

extension TerminalTabManagerLifecycleTests {
    @Suite(.serialized)
    @MainActor
    struct Tmux: TerminalTabManagerTestSupport {
        @Test
        func managedTmuxEndClosesItsLastPaneAndTab() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Managed tmux")
                installTab(tab, in: manager, connectionState: .connected)
                manager.remoteSessionCoordinator.setAttachment(
                    for: tab.rootPaneId,
                    identifier: remoteSessionIdentifier("vvterm_test"),
                    ownership: .managed
                )
                manager.remoteSessionCoordinator.updateStatus(.foreground, for: tab.rootPaneId)
    
                manager.handleShellEnd(for: tab.rootPaneId, reason: .remoteSessionTerminated(.managed))
    
                #expect(manager.sessionState.tabs(for: tab.serverId).isEmpty)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId) == nil)
                #expect(manager.remoteSessionCoordinator.attachment(for: tab.rootPaneId) == nil)
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
                manager.remoteSessionCoordinator.setAttachment(
                    for: secondPaneId,
                    identifier: remoteSessionIdentifier("vvterm_second"),
                    ownership: .managed
                )
                manager.remoteSessionCoordinator.updateStatus(.background, for: secondPaneId)
    
                manager.handleShellEnd(for: secondPaneId, reason: .remoteSessionTerminated(.managed))
    
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
                manager.remoteSessionCoordinator.setAttachment(
                    for: tab.rootPaneId,
                    identifier: remoteSessionIdentifier("vvterm_test"),
                    ownership: .managed
                )
                manager.remoteSessionCoordinator.updateStatus(.foreground, for: tab.rootPaneId)
    
                manager.handleShellEnd(for: tab.rootPaneId, reason: .remoteSessionDetached(.managed))
    
                #expect(manager.sessionState.tabs(for: tab.serverId) == [tab])
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == .remoteSessionDetached)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason?.allowsAutomaticReconnect == false)
                #expect(manager.remoteSessionCoordinator.attachment(for: tab.rootPaneId)?.attachment.identifier.rawValue == "vvterm_test")
                #expect(
                    manager.remoteSessionCoordinator.attachment(for: tab.rootPaneId)?
                        .managedSessionConfirmed == true
                )
            }
        }
    
        @Test
        func disconnectedTmuxProbePreservesConfirmedAttachmentInsteadOfReportingMissing() async {
            await withTmuxEnabled {
                await withCleanManager { manager in
                    let tab = TerminalTab(serverId: UUID(), title: "Long-idle tmux reconnect")
                    installTab(tab, in: manager, connectionState: .disconnected)
                    manager.remoteSessionCoordinator.setAttachment(
                        for: tab.rootPaneId,
                        identifier: remoteSessionIdentifier("vvterm_existing"),
                        ownership: .managed,
                        managedSessionConfirmed: true
                    )
                    manager.remoteSessionCoordinator.updateStatus(.background, for: tab.rootPaneId)
    
                    let disconnectedClient = SSHClient.testing()
                    guard let startToken = manager.transportCoordinator.beginShellStart(
                        for: tab.rootPaneId,
                        client: disconnectedClient
                    ) else {
                        Issue.record("Expected disconnected shell start")
                        return
                    }
    
                    do {
                        _ = try await manager.remoteSessionCoordinator.startupPlan(
                            for: tab.rootPaneId,
                            serverID: tab.serverId,
                            client: disconnectedClient,
                            startToken: startToken,
                            availabilityResolver: {
                                .indeterminate(.disconnected)
                            }
                        )
                        Issue.record("An indeterminate tmux probe should retry the connection")
                    } catch {
                        #expect(error is SSHError)
                    }
    
                    #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.remoteSessionStatus == .background)
                    #expect(manager.remoteSessionCoordinator.attachment(for: tab.rootPaneId) == TerminalRemoteSessionAttachmentState(
                        identifier: remoteSessionIdentifier("vvterm_existing"),
                        ownership: .managed,
                        managedSessionConfirmed: true
                    ))
                    #expect(manager.remoteSessionCoordinator.attachPrompt == nil)
    
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
                    manager.remoteSessionCoordinator.setAttachment(
                        for: tab.rootPaneId,
                        identifier: remoteSessionIdentifier("vvterm_existing"),
                        ownership: .managed,
                        managedSessionConfirmed: true
                    )
                    manager.remoteSessionCoordinator.updateStatus(.background, for: tab.rootPaneId)
    
                    let client = SSHClient.testing()
                    guard let startToken = manager.transportCoordinator.beginShellStart(
                        for: tab.rootPaneId,
                        client: client
                    ) else {
                        Issue.record("Expected shell start")
                        return
                    }
                    _ = try? await manager.remoteSessionCoordinator.startupPlan(
                        for: tab.rootPaneId,
                        serverID: tab.serverId,
                        client: client,
                        startToken: startToken,
                        availabilityResolver: { .confirmedMissing }
                    )
    
                    #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.remoteSessionStatus == .missing)
                    #expect(manager.remoteSessionCoordinator.attachment(for: tab.rootPaneId) == nil)
    
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
                    manager.remoteSessionCoordinator.setAttachment(
                        for: tab.rootPaneId,
                        identifier: remoteSessionIdentifier("vvterm_existing"),
                        ownership: .managed,
                        managedSessionConfirmed: true
                    )
                    manager.remoteSessionCoordinator.updateStatus(.background, for: tab.rootPaneId)
    
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
                            _ = try await manager.remoteSessionCoordinator.startupPlan(
                                for: tab.rootPaneId,
                                serverID: tab.serverId,
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
                    #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.remoteSessionStatus == .background)
                    #expect(manager.remoteSessionCoordinator.attachment(for: tab.rootPaneId) == TerminalRemoteSessionAttachmentState(
                        identifier: remoteSessionIdentifier("vvterm_existing"),
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
                    manager.remoteSessionCoordinator.setAttachment(
                        for: tab.rootPaneId,
                        identifier: remoteSessionIdentifier("vvterm_existing"),
                        ownership: .managed,
                        managedSessionConfirmed: true
                    )
                    manager.remoteSessionCoordinator.updateStatus(.background, for: tab.rootPaneId)
    
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
                            _ = try await manager.remoteSessionCoordinator.startupPlan(
                                for: tab.rootPaneId,
                                serverID: tab.serverId,
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
                    #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.remoteSessionStatus == .background)
                    #expect(manager.remoteSessionCoordinator.attachment(for: tab.rootPaneId) == TerminalRemoteSessionAttachmentState(
                        identifier: remoteSessionIdentifier("vvterm_existing"),
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
            let coordinator = TerminalRemoteSessionCoordinator()
            let paneId = UUID()
            let staleRequestId = UUID()
            let replacementRequestId = UUID()
    
            let staleSelection = Task { @MainActor in
                await coordinator.requestSelection(
                    requestID: staleRequestId,
                    paneID: paneId,
                    backendIdentifier: .tmux,
                    availableSessions: []
                )
            }
            guard await waitUntil({
                coordinator.hasPendingPrompt(requestID: staleRequestId)
            }) else {
                Issue.record("Stale tmux prompt was not enqueued")
                staleSelection.cancel()
                return
            }
    
            let replacementSelection = Task { @MainActor in
                await coordinator.requestSelection(
                    requestID: replacementRequestId,
                    paneID: paneId,
                    backendIdentifier: .tmux,
                    availableSessions: []
                )
            }
            guard await waitUntil({
                coordinator.hasPendingPrompt(requestID: replacementRequestId)
            }) else {
                Issue.record("Replacement tmux prompt was not enqueued")
                staleSelection.cancel()
                replacementSelection.cancel()
                return
            }
    
            staleSelection.cancel()
            #expect(await waitUntil({
                coordinator.attachPrompt?.id == replacementRequestId
                    && !coordinator.hasPendingPrompt(requestID: staleRequestId)
            }))
    
            coordinator.resolvePrompt(
                requestID: replacementRequestId,
                selection: .createManaged
            )
    
            #expect(await staleSelection.value == .plainShell)
            #expect(await replacementSelection.value == .createManaged)
        }
    
        @Test
        func managedReattachRequiresExplicitSessionConfirmation() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Unconfirmed tmux")
                installTab(tab, in: manager, connectionState: .connected)
                manager.remoteSessionCoordinator.setAttachment(
                    for: tab.rootPaneId,
                    identifier: remoteSessionIdentifier("vvterm_test"),
                    ownership: .managed
                )
    
                #expect(!manager.remoteSessionCoordinator.shouldReattachManagedSession(
                    for: tab.rootPaneId,
                    backendIdentifier: .tmux
                ))
    
                manager.remoteSessionCoordinator.confirmManagedSession(for: tab.rootPaneId)
    
                #expect(manager.remoteSessionCoordinator.shouldReattachManagedSession(
                    for: tab.rootPaneId,
                    backendIdentifier: .tmux
                ))
            }
        }
    
        @Test
        func managedSessionConfirmationRoundTripsWithoutPromotingUnconfirmedSessions() async {
            await withCleanManager { manager in
                let confirmedTab = TerminalTab(serverId: UUID(), title: "Confirmed tmux")
                let unconfirmedTab = TerminalTab(serverId: UUID(), title: "Unconfirmed tmux")
                installTab(confirmedTab, in: manager, connectionState: .connected)
                installTab(unconfirmedTab, in: manager, connectionState: .connected)
    
                manager.remoteSessionCoordinator.setAttachment(
                    for: confirmedTab.rootPaneId,
                    identifier: remoteSessionIdentifier("vvterm_confirmed"),
                    ownership: .managed,
                    managedSessionConfirmed: true
                )
                manager.remoteSessionCoordinator.setAttachment(
                    for: unconfirmedTab.rootPaneId,
                    identifier: remoteSessionIdentifier("vvterm_unconfirmed"),
                    ownership: .managed
                )
    
                manager.sessionState.persistAndRestoreSnapshotForTesting()
    
                #expect(manager.remoteSessionCoordinator.shouldReattachManagedSession(
                    for: confirmedTab.rootPaneId,
                    backendIdentifier: .tmux
                ))
                #expect(!manager.remoteSessionCoordinator.shouldReattachManagedSession(
                    for: unconfirmedTab.rootPaneId,
                    backendIdentifier: .tmux
                ))
            }
        }
    
        @Test
        func managedTmuxCreationFailurePreservesPaneAndClearsUnprovenAttachment() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Failed tmux")
                installTab(tab, in: manager, connectionState: .connected)
                manager.remoteSessionCoordinator.setAttachment(
                    for: tab.rootPaneId,
                    identifier: remoteSessionIdentifier("vvterm_test"),
                    ownership: .managed
                )
                manager.remoteSessionCoordinator.updateStatus(.foreground, for: tab.rootPaneId)
    
                manager.handleShellEnd(for: tab.rootPaneId, reason: .remoteSessionCreationFailed)
    
                #expect(manager.sessionState.tabs(for: tab.serverId) == [tab])
                #expect(
                    manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState
                        == .failed(.remoteSessionStartupFailed)
                )
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.remoteSessionStatus == .unknown)
                #expect(manager.remoteSessionCoordinator.attachment(for: tab.rootPaneId) == nil)
            }
        }
    
        @Test
        func successfulTmuxInstallTriggersExplicitReconnect() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Installed tmux")
                installTab(tab, in: manager, connectionState: .connected)
                manager.sessionState.updatePane(tab.rootPaneId) { $0.disconnectReason = .remoteSessionDetached }
                var reconnectRequested = false
    
                manager.remoteSessionCoordinator.completeInstall(
                    for: tab.rootPaneId,
                    attachment: remoteSessionAttachmentState(
                        "vvterm_installed",
                        ownership: .managed
                    ),
                    onInstalled: { reconnectRequested = true }
                )
    
                #expect(reconnectRequested)
                #expect(manager.remoteSessionCoordinator.attachment(for: tab.rootPaneId)?.attachment.identifier.rawValue == "vvterm_installed")
                #expect(manager.remoteSessionCoordinator.attachment(for: tab.rootPaneId)?.attachment.ownership == .managed)
            }
        }
    
        @Test
        func transportEndPreservesPaneAndAllowsAutomaticReconnect() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Dropped transport")
                installTab(tab, in: manager, connectionState: .connected)
    
                manager.handleShellEnd(for: tab.rootPaneId, reason: .transportInterrupted)
    
                #expect(manager.sessionState.tabs(for: tab.serverId) == [tab])
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .disconnected)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == .transportInterrupted)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason?.allowsAutomaticReconnect == true)
            }
        }

        @Test
        func completedStandaloneActionPreservesPaneWithoutAutomaticReconnect() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Completed action")
                installTab(tab, in: manager, connectionState: .connected)

                manager.handleShellEnd(
                    for: tab.rootPaneId,
                    reason: .standaloneStartupActionCompleted
                )

                #expect(manager.sessionState.tabs(for: tab.serverId) == [tab])
                #expect(
                    manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState
                        == .disconnected
                )
                #expect(
                    manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason
                        == .startupActionCompleted
                )
                #expect(
                    manager.sessionState.paneState(for: tab.rootPaneId)?
                        .disconnectReason?.allowsAutomaticReconnect == false
                )
            }
        }
    
        @Test
        func transientReconnectFailurePreservesAutomaticRetryEligibility() async {
            await withCleanManager { manager in
                let tab = TerminalTab(serverId: UUID(), title: "Transient retry")
                installTab(tab, in: manager, connectionState: .connected)
    
                manager.handleShellEnd(for: tab.rootPaneId, reason: .transportInterrupted)
                manager.updatePaneState(
                    tab.rootPaneId,
                    connectionState: .reconnecting(attempt: 1)
                )
                manager.handleConnectionFailure(
                    for: tab.rootPaneId,
                    failure: .transport(SSHError.timeout)
                )
    
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == .transportInterrupted)
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
    
                manager.handleShellEnd(for: tab.rootPaneId, reason: .transportInterrupted)
                manager.updatePaneState(
                    tab.rootPaneId,
                    connectionState: .reconnecting(attempt: 1)
                )
                manager.handleConnectionFailure(
                    for: tab.rootPaneId,
                    failure: .transport(UnclassifiedReconnectError())
                )
    
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == .transportInterrupted)
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
    
                manager.handleShellEnd(for: tab.rootPaneId, reason: .transportInterrupted)
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
                    reason: .transportInterrupted
                )
    
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.connectionState == .connected)
                #expect(manager.sessionState.paneState(for: tab.rootPaneId)?.disconnectReason == nil)
                #expect(manager.transportCoordinator.activeSSHRoute(for: tab.rootPaneId)?.shellId == activeShellId)
            }
        }
    }
}
