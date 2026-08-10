//
//  TerminalTabManager.swift
//  VVTerm
//
//  Manages terminal tabs and their panes.
//  - Tabs are shown in the toolbar
//  - Each tab can have multiple panes via splits
//  - Panes are NOT tabs - they're split views within a tab
//

import Foundation
import SwiftUI
import Combine
import os.log

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

nonisolated enum TerminalVoicePresentationState: Equatable, Sendable {
    nonisolated enum Event: Equatable, Sendable {
        case recordingStarted
        case recordingStopped
        case transcriptionSent
        case pendingReturnDismissed
    }

    case idle
    case recording
    case pendingReturn

    var isRecording: Bool { self == .recording }
    var isPendingReturn: Bool { self == .pendingReturn }

    func applying(_ event: Event) -> Self {
        switch event {
        case .recordingStarted:
            return .recording
        case .recordingStopped:
            return self == .recording ? .idle : self
        case .transcriptionSent:
            return .pendingReturn
        case .pendingReturnDismissed:
            return self == .pendingReturn ? .idle : self
        }
    }
}

@MainActor
final class TerminalTabManager: ObservableObject {
    private enum TmuxInstallOutcome: Sendable {
        case installed(sessionName: String)
        case unavailable
        case missing
        case indeterminate
    }

    /// DEV-228-only compatibility composition for the Remote Files default initializer.
    /// App roots construct and inject their own manager instead.
    static let shared = TerminalTabManagerLiveComposition.makeManager(
        appLockManager: .shared,
        serverManager: .shared,
        engagementTracker: EngagementTracker(dependencies: .live)
    )

    // MARK: - Session State

    let sessionState: TerminalSessionStateStore
    let connectionViewSelections: ConnectionViewSelectionStore

    /// Tabs temporarily presenting only their focused pane. The focused pane is
    /// still derived from TerminalTab, and this presentation state is not persisted.
    @Published private(set) var splitZoomedTabIds: Set<UUID> = []

    /// Servers with at least one live terminal shell.
    var connectedServerIds: Set<UUID> {
        Set(sessionState.allPaneStates.compactMap { state in
            guard state.connectionState.isConnected,
                  transportRegistry.hasLiveTransport(for: state.paneId) else {
                return nil
            }
            return state.serverId
        })
    }

    // MARK: - Terminal Registry

    let terminalSurfaceStore: any TerminalSurfaceStoring
    private let transportRegistry = TerminalTransportRegistry<EternalTerminalRuntime>(
        staleShellStartThreshold: 120
    )
    private var eternalTerminalResumeStore: any EternalTerminalResumeStoring
    private let defaultEternalTerminalResumeStore: any EternalTerminalResumeStoring
    private let moshRecovery: any TerminalMoshRecoveryServicing
    lazy var reconnectCoordinator = TerminalReconnectCoordinator(
        onEvent: { [weak self] event in
            self?.logReconnectEvent(event)
        },
        onChange: { [weak self] in
            self?.objectWillChange.send()
        }
    )
    private var terminalConnectionGenerations: [UUID: UUID] = [:]
    private var networkReadinessCancellable: AnyCancellable?
    #if os(macOS)
    var macRecoveryGate = MacTerminalRecoveryGate()
    var activeMacRecoveryGeneration: UUID?
    var activeMacRecoveryReconciliationID: UUID?
    var macRecoveryTask: Task<Void, Never>?
    #elseif os(iOS)
    var iosNetworkRecoveryGate = TerminalNetworkRecoveryGate()
    #endif
    /// Server IDs with an in-flight tab-open request to avoid queued duplicates.
    private var tabOpensInFlight: Set<UUID> = []

    @Published private(set) var runtimeTitleByPane: [UUID: String] = [:]
    @Published private(set) var titleOverrideByPane: [UUID: String] = [:]
    #if os(iOS)
    @Published private(set) var terminalFindNavigatorVisibleByPane: [UUID: Bool] = [:]
    @Published private(set) var terminalVoicePresentationByPane: [UUID: TerminalVoicePresentationState] = [:]
    let keyboardCoordinator = TerminalKeyboardCoordinator()
    #endif

    @Published var tmuxAttachPrompt: TmuxAttachPrompt?

    let tmuxResolver: TmuxAttachResolver

    /// Servers that already ran tmux cleanup (per app launch)
    private var tmuxCleanupServers: Set<UUID> = []

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "TerminalTabManager")

    private let dependencies: TerminalTabManagerDependencies
    private(set) var currentNetworkReadiness: TerminalNetworkReadiness
    private var stateCancellables: Set<AnyCancellable> = []

    init(
        snapshotStore: any TerminalTabSnapshotStoring,
        dependencies: TerminalTabManagerDependencies,
        terminalSurfaceStore: any TerminalSurfaceStoring,
        eternalTerminalResumeStore: any EternalTerminalResumeStoring,
        moshRecovery: any TerminalMoshRecoveryServicing
    ) {
        self.dependencies = dependencies
        self.currentNetworkReadiness = dependencies.networkReadiness.initial
        let tmuxResolver = TmuxAttachResolver(
            configuration: dependencies.tmuxConfiguration,
            remoteTmux: dependencies.remoteTmux
        )
        let connectionViewSelections = ConnectionViewSelectionStore()
        self.tmuxResolver = tmuxResolver
        self.connectionViewSelections = connectionViewSelections
        self.sessionState = TerminalSessionStateStore(
            snapshotStore: snapshotStore,
            connectionViewSelections: connectionViewSelections,
            tmuxResolver: tmuxResolver
        )
        self.terminalSurfaceStore = terminalSurfaceStore
        self.eternalTerminalResumeStore = eternalTerminalResumeStore
        self.defaultEternalTerminalResumeStore = eternalTerminalResumeStore
        self.moshRecovery = moshRecovery
        #if os(iOS)
        keyboardCoordinator.terminalProvider = { [weak self] paneId in
            self?.terminalSurfaceStore.surface(for: paneId)?.keyboardInputSession
        }
        #endif
        terminalSurfaceStore.changes
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &stateCancellables)
        sessionState.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &stateCancellables)
        connectionViewSelections.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &stateCancellables)
        sessionState.selectedTabChanges
            .dropFirst()
            .sink { [weak self] selectedTabs in
                self?.updateTmuxSelectionStatuses(selectedTabs: selectedTabs)
            }
            .store(in: &stateCancellables)
        sessionState.paneConnectionStateChanges
            .dropFirst()
            .sink { [weak self] connectionStates in
                self?.dependencies.effects.refreshLiveActivity(connectionStates)
            }
            .store(in: &stateCancellables)
        networkReadinessCancellable = dependencies.networkReadiness.updates
            .sink { [weak self] readiness in
                self?.currentNetworkReadiness = readiness
                #if os(macOS)
                self?.handleMacRecoverySignal(.networkChanged(readiness))
                #elseif os(iOS)
                self?.handleIOSNetworkReadinessChange(readiness)
                #endif
            }
        dependencies.effects.refreshLiveActivity(
            sessionState.connectionStates
        )
    }

    #if DEBUG
    convenience init(
        snapshotStore: any TerminalTabSnapshotStoring,
        networkReadinessPublisher: AnyPublisher<TerminalNetworkReadiness, Never>?,
        liveActivityRefresh: @escaping ([ConnectionState]) -> Void,
        terminalSurfaceStore: any TerminalSurfaceStoring,
        eternalTerminalResumeStore: any EternalTerminalResumeStoring,
        moshRecovery: any TerminalMoshRecoveryServicing
    ) {
        self.init(
            snapshotStore: snapshotStore,
            dependencies: .testing(
                networkReadinessPublisher: networkReadinessPublisher,
                liveActivityRefresh: liveActivityRefresh
            ),
            terminalSurfaceStore: terminalSurfaceStore,
            eternalTerminalResumeStore: eternalTerminalResumeStore,
            moshRecovery: moshRecovery
        )
    }
    #endif

    private func paneTmuxStatus(for paneId: UUID) -> TmuxStatus? {
        sessionState.paneState(for: paneId)?.tmuxStatus
    }

    private func setPaneTmuxStatus(_ status: TmuxStatus, for paneId: UUID) {
        guard let previousStatus = sessionState.paneState(for: paneId)?.tmuxStatus,
              previousStatus != status else { return }
        sessionState.updatePane(paneId) { $0.tmuxStatus = status }
        logger.info(
            "Tmux status for pane \(paneId.uuidString, privacy: .public) changed from \(previousStatus.rawValue, privacy: .public) to \(status.rawValue, privacy: .public)"
        )
    }

    private func paneWorkingDirectory(for paneId: UUID) -> String? {
        sessionState.paneState(for: paneId)?.workingDirectory
    }

    private func setPaneWorkingDirectory(_ workingDirectory: String, for paneId: UUID) {
        sessionState.updatePane(paneId) { $0.workingDirectory = workingDirectory }
    }

    private func setPanePresentationOverrides(_ presentationOverrides: TerminalPresentationOverrides, for paneId: UUID) {
        sessionState.updatePane(paneId) { $0.presentationOverrides = presentationOverrides }
    }

    private func setPaneTitle(_ title: String, for paneId: UUID) {
        guard runtimeTitleByPane[paneId] != title else { return }

        runtimeTitleByPane[paneId] = title
        logger.info("Runtime pane title changed: \(title, privacy: .public)")
    }

    private func setPaneTransport(_ state: ShellTransportState, for paneId: UUID) {
        sessionState.updatePane(paneId) { $0.transportState = state }
    }

    private func handleStaleShellStartContext(
        _ staleContext: SSHShellRegistry.StartContext?,
        logMessage: StaticString,
        paneId: UUID
    ) {
        guard let staleContext else { return }

        logger.warning("\(logMessage) \(paneId.uuidString, privacy: .public)")
        tmuxResolver.cancelPrompt(
            requestId: staleContext.token.id,
            setPrompt: setTmuxAttachPrompt
        )
        if !transportRegistry.hasClientReferences(staleContext.client) {
            Task.detached(priority: .utility) { [client = staleContext.client] in
                await client.disconnect()
            }
        }
    }

    // MARK: - Tab Management

    /// Get tabs for a server
    func tabs(for serverId: UUID) -> [TerminalTab] {
        sessionState.tabs(for: serverId)
    }

    /// Get currently selected tab for a server
    func selectedTab(for serverId: UUID) -> TerminalTab? {
        sessionState.selectedTab(for: serverId)
    }

    func selectedTabId(for serverId: UUID) -> UUID? {
        sessionState.selectedTabId(for: serverId)
    }

    func selectTab(_ tabId: UUID?, for serverId: UUID) {
        sessionState.selectTab(tabId, for: serverId)
    }

    func selectedView(for serverId: UUID) -> ConnectionViewTabID? {
        connectionViewSelections.selection(for: serverId)
    }

    func selectView(_ view: ConnectionViewTabID, for serverId: UUID) {
        connectionViewSelections.setSelection(view, for: serverId)
        sessionState.requestPersistence()
    }

    func paneState(for paneId: UUID) -> TerminalPaneState? {
        sessionState.paneState(for: paneId)
    }

    func serverIdsWithTabs() -> Set<UUID> {
        sessionState.serverIdsWithTabs
    }

    func workingDirectoryCandidate(for serverId: UUID) -> String? {
        if let selectedTab = selectedTab(for: serverId),
           let directory = workingDirectory(for: selectedTab.focusedPaneId) {
            return directory
        }
        return sessionState.firstPaneState(for: serverId)?.workingDirectory
    }

    /// Check if can open new tab (Pro limit check)
    func canOpenNewTab(hasProAccess: Bool) -> Bool {
        sessionState.canOpenNewTab(hasProAccess: hasProAccess)
    }

    private func hasLiveTerminalShell(for serverId: UUID) -> Bool {
        connectedServerIds.contains(serverId)
    }

    /// Open a new tab for a server
    @discardableResult
    func openTab(for server: Server) async throws -> TerminalTab {
        if tabOpensInFlight.contains(server.id) {
            throw VVTermError.connectionFailed(
                String(localized: "A tab is already opening for this server.")
            )
        }
        tabOpensInFlight.insert(server.id)
        defer { tabOpensInFlight.remove(server.id) }

        guard await dependencies.effects.authorizeServer(server) else {
            throw VVTermError.authenticationFailed
        }

        let sourcePaneId = selectedTab(for: server.id)?.focusedPaneId
        let sourceWorkingDirectory = sourcePaneId
            .flatMap { sessionState.paneState(for: $0)?.workingDirectory }
        let tab = sessionState.createTab(
            serverId: server.id,
            title: server.name,
            sourcePaneId: sourcePaneId,
            sourceWorkingDirectory: sourceWorkingDirectory,
            tmuxStatus: tmuxResolver.isTmuxEnabled(for: server.id) ? .unknown : .off
        )

        logger.info("Opened new tab for \(server.name), pane: \(tab.rootPaneId)")
        return tab
    }

    /// Close a tab
    func closeTab(_ tab: TerminalTab) {
        closeTab(tab, intent: .explicitClose)
    }

    private func closeTab(
        _ tab: TerminalTab,
        intent: TerminalTeardownIntent
    ) {
        guard let currentTab = tabs(for: tab.serverId).first(where: { $0.id == tab.id }) else {
            logger.warning("closeTab: tab not found \(tab.id.uuidString, privacy: .public)")
            return
        }

        splitZoomedTabIds.remove(currentTab.id)

        // Clean up all panes in this tab
        for paneId in currentTab.allPaneIds {
            cleanupPane(paneId, intent: intent)
        }

        sessionState.removeTab(currentTab)

        dependencies.effects.noteTerminalSessionEnded(hasConnectedPanes)

        logger.info("Closed tab \(currentTab.id)")
    }

    /// Close all tabs for a server
    func closeAllTabs(for serverId: UUID) {
        closeAllTabs(for: serverId, intent: .explicitClose)
    }

    private func closeAllTabs(
        for serverId: UUID,
        intent: TerminalTeardownIntent
    ) {
        let serverTabs = tabs(for: serverId)
        for tab in serverTabs {
            closeTab(tab, intent: intent)
        }
    }

    /// Disconnect all terminal tabs for a specific server.
    func disconnectServer(_ serverId: UUID) {
        closeAllTabs(for: serverId, intent: .explicitServerDisconnect)
        sessionState.removeServer(serverId)
        connectionViewSelections.setSelection(nil, for: serverId)
        sessionState.persistNow()
        logger.info("Disconnected all terminal tabs for server \(serverId.uuidString, privacy: .public)")
    }

    /// Disconnect every active terminal tab.
    func disconnectAll() {
        let serverIds = sessionState.serverIdsWithTabs.union(connectedServerIds)
        for serverId in serverIds {
            disconnectServer(serverId)
        }
        sessionState.persistNow()
        logger.info("Disconnected all terminal tabs")
    }

    /// Flushes reconnectable state and releases local runtime resources without
    /// deleting tabs or terminating remote resumable sessions.
    @discardableResult
    func beginApplicationTermination() -> Task<Void, Never> {
        let paneIds = sessionState.prepareForApplicationTermination()
            .union(transportRegistry.ownedPaneIds)

        for paneId in paneIds {
            transportRegistry.cancelConnectionTask(for: paneId)
        }
        reconnectCoordinator.invalidateAll()
        #if os(macOS)
        macRecoveryTask?.cancel()
        macRecoveryTask = nil
        activeMacRecoveryGeneration = nil
        activeMacRecoveryReconciliationID = nil
        #elseif os(iOS)
        iosNetworkRecoveryGate = TerminalNetworkRecoveryGate()
        #endif
        tabOpensInFlight.removeAll()
        for paneId in paneIds {
            detachTerminalRegistration(for: paneId)
        }
        runtimeTitleByPane.removeAll()

        logger.info("Preserved terminal tabs while releasing application runtime state")
        return Task { [weak self] in
            guard let self else { return }
            await self.prepareResumableSessionsForApplicationBackground()
            for paneId in paneIds {
                await self.unregisterSSHClient(for: paneId)
                await self.unregisterEternalTerminalRuntime(for: paneId)
            }
        }
    }

    func invalidateReconnectPreparations(for serverId: UUID) {
        // Keep route departure synchronous. Suspended preparation may finish
        // its bounded wait, but cannot mutate the preserved pane afterward.
        for paneState in sessionState.paneStates(forServer: serverId) {
            reconnectCoordinator.invalidate(for: paneState.paneId)
        }
    }

    func reconnectAttempt(for paneId: UUID) -> TerminalReconnectCoordinator.Attempt? {
        reconnectCoordinator.attempt(for: paneId)
    }

    func terminalConnectionGeneration(for paneId: UUID) -> UUID {
        terminalConnectionGenerations[paneId] ?? paneId
    }

    #if os(macOS)
    func hasVerifiedLiveTransport(
        for paneId: UUID,
        eternalTerminalProbeID: UUID? = nil
    ) async -> Bool {
        guard let paneState = sessionState.paneState(for: paneId) else { return false }
        if paneState.activeTransport == .eternalTerminal {
            let runtime = transportRegistry.runtime(for: paneId)
            let completedProbe = eternalTerminalProbeID.map {
                runtime?.completedNetworkRecoveryProbe($0) == true
            } ?? false
            return MacTerminalRecoveryPolicy.hasVerifiedLiveTransport(
                connectionState: paneState.connectionState,
                activeTransport: paneState.activeTransport,
                hasEternalTerminalRuntime: runtime != nil,
                hasShellOwnership: false,
                transportIsLive: completedProbe
            )
        }
        let route = transportRegistry.shellRoute(for: paneId)
        let client = route?.client
        let shellId = route?.shellId
        let transportIsLive = if let client, let shellId {
            await client.probeLiveTransport(
                shellId: shellId,
                transport: paneState.activeTransport
            )
        } else {
            false
        }
        return MacTerminalRecoveryPolicy.hasVerifiedLiveTransport(
            connectionState: paneState.connectionState,
            activeTransport: paneState.activeTransport,
            hasEternalTerminalRuntime: transportRegistry.runtime(for: paneId) != nil,
            hasShellOwnership: shellId != nil && client != nil,
            transportIsLive: transportIsLive
        )
    }
    #endif

    @discardableResult
    func requestReconnect(
        for paneId: UUID,
        requiresReadyNetwork: Bool,
        generation: UUID = UUID(),
        replacingCurrent: Bool = false
    ) -> Bool {
        requestReconnect(
            for: paneId,
            requiresReadyNetwork: requiresReadyNetwork,
            generation: generation,
            replacingCurrent: replacingCurrent,
            networkReadiness: currentNetworkReadiness
        )
    }

    @discardableResult
    func requestReconnect(
        for paneId: UUID,
        requiresReadyNetwork: Bool,
        generation: UUID,
        replacingCurrent: Bool,
        networkReadiness: TerminalNetworkReadiness
    ) -> Bool {
        guard sessionState.containsPane(paneId) else { return false }
        let networkIsReady = networkReadiness == .ready
        guard !requiresReadyNetwork || networkIsReady else { return false }

        #if os(iOS)
        if networkReadiness == .unavailable {
            return queueIOSReconnectUntilNetworkReady(
                for: paneId,
                replacingCurrent: replacingCurrent
            )
        }
        #endif

        return makeReconnectAttempt(
            for: paneId,
            generation: generation,
            networkIsReady: !requiresReadyNetwork || networkIsReady,
            replacingCurrent: replacingCurrent
        )
    }

    @discardableResult
    func requestReconnectWaitingForNetwork(
        for paneId: UUID,
        generation: UUID,
        replacingCurrent: Bool
    ) -> Bool {
        guard sessionState.containsPane(paneId) else { return false }
        return makeReconnectAttempt(
            for: paneId,
            generation: generation,
            networkIsReady: false,
            replacingCurrent: replacingCurrent
        )
    }

    private func makeReconnectAttempt(
        for paneId: UUID,
        generation: UUID,
        networkIsReady: Bool,
        replacingCurrent: Bool
    ) -> Bool {
        reconnectCoordinator.request(
            paneId: paneId,
            generation: generation,
            networkIsReady: networkIsReady,
            replacingCurrent: replacingCurrent,
            cleanup: { [weak self] attempt in
                await self?.cleanupConnectionForReconnect(attempt)
            },
            start: { [weak self] attempt in
                self?.beginConnection(after: attempt)
            },
            fail: { [weak self] attempt in
                self?.failReconnect(attempt)
            }
        ) != nil
    }

    private func cleanupConnectionForReconnect(
        _ attempt: TerminalReconnectCoordinator.Attempt
    ) async {
        let paneId = attempt.paneId
        logger.info(
            "Reconnect abort stage pane=\(paneId.uuidString, privacy: .public) attempt=\(attempt.id.uuidString, privacy: .public) generation=\(attempt.generation.uuidString, privacy: .public) monotonic=\(Foundation.ProcessInfo.processInfo.systemUptime, privacy: .public)"
        )
        transportRegistry.cancelConnectionTask(for: paneId)
        let client = transportRegistry.connectionClient(for: paneId)
        let shellId = transportRegistry.shellId(for: paneId)
        let startToken = transportRegistry.connectionStartToken(for: paneId)
        let eternalTerminalRuntime = transportRegistry.runtime(for: paneId)
        let detachedEternalTerminalRuntime = eternalTerminalRuntime.flatMap { runtime in
            detachEternalTerminalRuntime(for: paneId, ifOwnedBy: runtime) ? runtime : nil
        }

        if let client,
           !transportRegistry.hasOtherClientReferences(using: client, excluding: paneId) {
            await client.abortConnection()
        }
        detachedEternalTerminalRuntime?.abortConnection()

        async let sshCleanup: Void = {
            if let client, let shellId {
                await unregisterSSHClient(
                    for: paneId,
                    ifOwnedBy: client,
                    shellId: shellId
                )
            } else if let startToken {
                await unregisterSSHClient(for: paneId, ifOwnedBy: startToken)
            }
        }()
        async let eternalTerminalCleanup: Void = {
            await detachedEternalTerminalRuntime?.close()
        }()
        _ = await (sshCleanup, eternalTerminalCleanup)
    }

    private func beginConnection(after attempt: TerminalReconnectCoordinator.Attempt) {
        guard reconnectCoordinator.attempt(for: attempt.paneId)?.id == attempt.id,
              let paneState = sessionState.paneState(for: attempt.paneId) else {
            logger.info(
                "Ignoring stale reconnect preparation result \(attempt.id.uuidString, privacy: .public)"
            )
            return
        }
        #if os(iOS)
        if currentNetworkReadiness == .unavailable {
            queueIOSReconnectUntilNetworkReady(for: attempt.paneId)
            return
        }
        let windowSceneIsActive = terminalSurfaceStore
            .surface(for: attempt.paneId)?
            .isHostingSceneActive ?? true
        guard dependencies.applicationIsActive(),
              windowSceneIsActive else {
            reconnectCoordinator.complete(for: attempt.paneId)
            updatePaneState(attempt.paneId, connectionState: .disconnected)
            return
        }
        #endif
        terminalConnectionGenerations[attempt.paneId] = UUID()
        updatePaneState(
            attempt.paneId,
            connectionState: TerminalConnectionAttemptPolicy.state(
                attempt: 1,
                hasEstablishedConnection: paneState.hasEstablishedConnection
            )
        )
    }

    private func failReconnect(_ attempt: TerminalReconnectCoordinator.Attempt) {
        guard sessionState.containsPane(attempt.paneId) else { return }
        logger.error(
            "Reconnect deadline exceeded for pane \(attempt.paneId.uuidString, privacy: .public), attempt \(attempt.id.uuidString, privacy: .public)"
        )
        if sessionState.paneState(for: attempt.paneId)?.disconnectReason != nil {
            sessionState.updatePane(attempt.paneId, persist: true) {
                $0.disconnectReason = nil
            }
        }
        updatePaneState(
            attempt.paneId,
            connectionState: .failed(String(localized: "Connection timed out. Please retry."))
        )
    }

    private func logReconnectEvent(_ event: TerminalReconnectCoordinator.Event) {
        logger.info(
            "Reconnect stage=\(event.stage.rawValue, privacy: .public) monotonic=\(event.systemUptime, privacy: .public) pane=\(event.attempt.paneId.uuidString, privacy: .public) attempt=\(event.attempt.id.uuidString, privacy: .public) generation=\(event.attempt.generation.uuidString, privacy: .public)"
        )
    }

    func clearMoshFallbackDiagnostics(for paneId: UUID) {
        sessionState.updatePane(paneId) { $0.transportState.clearFallbackDiagnostics() }
    }

    // MARK: - Split Management

    /// Split a pane horizontally (left | right)
    func splitHorizontal(
        tab: TerminalTab,
        paneId: UUID,
        hasProAccess: Bool
    ) -> UUID? {
        splitRight(tab: tab, paneId: paneId, hasProAccess: hasProAccess)
    }

    /// Split a pane vertically (top / bottom)
    func splitVertical(
        tab: TerminalTab,
        paneId: UUID,
        hasProAccess: Bool
    ) -> UUID? {
        splitDown(tab: tab, paneId: paneId, hasProAccess: hasProAccess)
    }

    func splitRight(tab: TerminalTab, paneId: UUID, hasProAccess: Bool) -> UUID? {
        splitPane(
            tab: tab,
            paneId: paneId,
            placement: .right,
            hasProAccess: hasProAccess
        )
    }

    func splitLeft(tab: TerminalTab, paneId: UUID, hasProAccess: Bool) -> UUID? {
        splitPane(
            tab: tab,
            paneId: paneId,
            placement: .left,
            hasProAccess: hasProAccess
        )
    }

    func splitDown(tab: TerminalTab, paneId: UUID, hasProAccess: Bool) -> UUID? {
        splitPane(
            tab: tab,
            paneId: paneId,
            placement: .down,
            hasProAccess: hasProAccess
        )
    }

    func splitUp(tab: TerminalTab, paneId: UUID, hasProAccess: Bool) -> UUID? {
        splitPane(
            tab: tab,
            paneId: paneId,
            placement: .up,
            hasProAccess: hasProAccess
        )
    }

    private func splitPane(
        tab: TerminalTab,
        paneId: UUID,
        placement: TerminalSplitPlacement,
        hasProAccess: Bool
    ) -> UUID? {
        guard hasProAccess else { return nil }
        let newPaneId = createSplitPane(tab: tab, paneId: paneId, placement: placement)
        if newPaneId != nil {
            dependencies.effects.recordSplitPaneCreated()
        }
        return newPaneId
    }

    private func createSplitPane(tab: TerminalTab, paneId: UUID, placement: TerminalSplitPlacement) -> UUID? {
        guard let currentTab = sessionState.tab(id: tab.id, for: tab.serverId),
              let newPaneId = sessionState.createSplitPane(
                  in: currentTab,
                  paneId: paneId,
                  placement: placement,
                  tmuxStatus: tmuxResolver.isTmuxEnabled(for: currentTab.serverId) ? .unknown : .off
              ) else {
            logger.warning("createSplitPane: tab or pane not found")
            return nil
        }
        if let updatedTab = sessionState.tab(id: currentTab.id, for: currentTab.serverId) {
            updateTmuxFocus(for: updatedTab)
        }
        logger.info("Split pane \(paneId) \(placement.direction.rawValue), new pane: \(newPaneId)")
        return newPaneId
    }

    /// Close a pane within a tab
    func closePane(tab: TerminalTab, paneId: UUID) {
        closePane(tab: tab, paneId: paneId, intent: .explicitClose)
    }

    private func closePane(
        tab: TerminalTab,
        paneId: UUID,
        intent: TerminalTeardownIntent
    ) {
        guard let removal = sessionState.removePane(in: tab, paneId: paneId) else {
            logger.warning("closePane: tab not found")
            return
        }
        switch removal {
        case .closeTab(let currentTab):
            closeTab(currentTab, intent: intent)
        case .removed(let removedPaneId, let paneState, let updatedTab):
            updateTmuxFocus(for: updatedTab)
            cleanupPane(
                removedPaneId,
                removedPaneState: paneState,
                intent: intent
            )
            logger.info("Closed pane \(removedPaneId)")
        }
    }

    /// Update a tab in the tabs array
    func updateTab(_ tab: TerminalTab) {
        guard sessionState.replaceTab(tab) else { return }
        if !tab.hasSplits {
            splitZoomedTabIds.remove(tab.id)
        }
        updateTmuxFocus(for: tab)
    }

    func focusPane(in tab: TerminalTab, paneId: UUID) {
        guard let updatedTab = sessionState.focusPane(in: tab, paneId: paneId) else { return }
        updateTmuxFocus(for: updatedTab)
    }

    func updateSplitRatio(
        in tab: TerminalTab,
        node: TerminalSplitNode,
        ratio: Double
    ) {
        guard let updatedTab = sessionState.updateSplitRatio(
            in: tab,
            node: node,
            ratio: ratio
        ) else { return }
        updateTmuxFocus(for: updatedTab)
    }

    func equalizeSplitLayout(in tab: TerminalTab) {
        guard let updatedTab = sessionState.equalizeSplitLayout(in: tab) else { return }
        updateTmuxFocus(for: updatedTab)
    }

    func isSplitZoomed(in tab: TerminalTab) -> Bool {
        guard splitZoomedTabIds.contains(tab.id),
              let currentTab = tabs(for: tab.serverId).first(where: { $0.id == tab.id }) else {
            return false
        }
        return currentTab.hasSplits
    }

    func canPerformSplitCommand(
        _ command: TerminalSplitCommand,
        in tab: TerminalTab
    ) -> Bool {
        guard let currentTab = tabs(for: tab.serverId).first(where: { $0.id == tab.id }),
              currentTab.allPaneIds.contains(currentTab.focusedPaneId) else {
            return false
        }

        switch command {
        case .splitRight, .splitDown, .closeFocusedPane:
            return true
        case .toggleZoom, .selectPrevious, .selectNext, .equalize:
            return currentTab.hasSplits
        case .selectAbove:
            return currentTab.layout?.neighboringPane(
                from: currentTab.focusedPaneId,
                direction: .above
            ) != nil
        case .selectBelow:
            return currentTab.layout?.neighboringPane(
                from: currentTab.focusedPaneId,
                direction: .below
            ) != nil
        case .selectLeft:
            return currentTab.layout?.neighboringPane(
                from: currentTab.focusedPaneId,
                direction: .left
            ) != nil
        case .selectRight:
            return currentTab.layout?.neighboringPane(
                from: currentTab.focusedPaneId,
                direction: .right
            ) != nil
        case .moveDividerUp:
            return currentTab.layout?.hasDivider(
                near: currentTab.focusedPaneId,
                direction: .up
            ) == true
        case .moveDividerDown:
            return currentTab.layout?.hasDivider(
                near: currentTab.focusedPaneId,
                direction: .down
            ) == true
        case .moveDividerLeft:
            return currentTab.layout?.hasDivider(
                near: currentTab.focusedPaneId,
                direction: .left
            ) == true
        case .moveDividerRight:
            return currentTab.layout?.hasDivider(
                near: currentTab.focusedPaneId,
                direction: .right
            ) == true
        }
    }

    @discardableResult
    func performSplitCommand(
        _ command: TerminalSplitCommand,
        in tab: TerminalTab,
        hasProAccess: Bool
    ) -> TerminalSplitCommandOutcome {
        guard canPerformSplitCommand(command, in: tab),
              let currentTab = tabs(for: tab.serverId).first(where: { $0.id == tab.id }) else {
            return .unavailable
        }

        switch command {
        case .splitRight:
            guard hasProAccess else { return .requiresUpgrade }
            return splitRight(
                tab: currentTab,
                paneId: currentTab.focusedPaneId,
                hasProAccess: hasProAccess
            ) == nil
                ? .unavailable
                : .performed
        case .splitDown:
            guard hasProAccess else { return .requiresUpgrade }
            return splitDown(
                tab: currentTab,
                paneId: currentTab.focusedPaneId,
                hasProAccess: hasProAccess
            ) == nil
                ? .unavailable
                : .performed
        case .closeFocusedPane:
            return .requiresCloseConfirmation
        case .toggleZoom:
            if splitZoomedTabIds.contains(currentTab.id) {
                splitZoomedTabIds.remove(currentTab.id)
            } else {
                splitZoomedTabIds.insert(currentTab.id)
            }
        case .selectPrevious:
            guard let paneId = currentTab.layout?.pane(before: currentTab.focusedPaneId) else {
                return .unavailable
            }
            guard let updatedTab = sessionState.selectAdjacentPane(in: currentTab, paneId: paneId) else {
                return .unavailable
            }
            updateTmuxFocus(for: updatedTab)
        case .selectNext:
            guard let paneId = currentTab.layout?.pane(after: currentTab.focusedPaneId) else {
                return .unavailable
            }
            guard let updatedTab = sessionState.selectAdjacentPane(in: currentTab, paneId: paneId) else {
                return .unavailable
            }
            updateTmuxFocus(for: updatedTab)
        case .selectAbove:
            return selectNeighbor(in: currentTab, direction: .above)
        case .selectBelow:
            return selectNeighbor(in: currentTab, direction: .below)
        case .selectLeft:
            return selectNeighbor(in: currentTab, direction: .left)
        case .selectRight:
            return selectNeighbor(in: currentTab, direction: .right)
        case .equalize:
            guard let updatedTab = sessionState.equalizeSplitLayout(in: currentTab) else {
                return .unavailable
            }
            updateTmuxFocus(for: updatedTab)
        case .moveDividerUp:
            return moveDivider(in: currentTab, direction: .up)
        case .moveDividerDown:
            return moveDivider(in: currentTab, direction: .down)
        case .moveDividerLeft:
            return moveDivider(in: currentTab, direction: .left)
        case .moveDividerRight:
            return moveDivider(in: currentTab, direction: .right)
        }

        return .performed
    }

    private func selectNeighbor(
        in tab: TerminalTab,
        direction: TerminalSplitFocusDirection
    ) -> TerminalSplitCommandOutcome {
        guard let currentTab = tabs(for: tab.serverId).first(where: { $0.id == tab.id }),
              let paneId = currentTab.layout?.neighboringPane(
                  from: currentTab.focusedPaneId,
                  direction: direction
              ) else {
            return .unavailable
        }
        guard let updatedTab = sessionState.selectAdjacentPane(in: currentTab, paneId: paneId) else {
            return .unavailable
        }
        updateTmuxFocus(for: updatedTab)
        return .performed
    }

    private func moveDivider(
        in tab: TerminalTab,
        direction: TerminalSplitResizeDirection
    ) -> TerminalSplitCommandOutcome {
        guard let updatedTab = sessionState.moveDivider(in: tab, direction: direction) else {
            return .unavailable
        }
        updateTmuxFocus(for: updatedTab)
        return .performed
    }

    // MARK: - Terminal Registry

    func registerTerminalSurface(_ terminal: any TerminalSurface, for paneId: UUID) {
        #if os(iOS)
        terminal.setLifecycleCallbacks(TerminalSurfaceLifecycleCallbacks(
            windowAttachmentChanged: { [weak self, weak terminal] _ in
                Task { @MainActor [weak self, weak terminal] in
                    guard let self, let terminal,
                          self.terminalSurfaceStore.isRegistered(
                            terminal,
                            for: paneId
                          ) else { return }
                    self.keyboardCoordinator.setWindowAttached(
                        terminal.isAttachedToWindow,
                        for: paneId
                    )
                }
            },
            directTouch: { [weak self, weak terminal] isFocusTap in
                guard let self, let terminal,
                      self.terminalSurfaceStore.isRegistered(
                        terminal,
                        for: paneId
                      ) else { return }
                self.keyboardCoordinator.setActivePane(paneId)
                self.keyboardCoordinator.directTouchOnTerminal(isFocusTap: isFocusTap)
            },
            keyboardAccessoryHideRequested: { [weak self] in
                self?.keyboardCoordinator.userRequestedHide()
            },
            findNavigatorVisibilityChanged: { [weak self, weak terminal] isVisible in
                guard let self, let terminal,
                      self.terminalSurfaceStore.isRegistered(
                        terminal,
                        for: paneId
                      ) else { return }
                self.setTerminalFindNavigatorVisible(isVisible, for: paneId)
                self.keyboardCoordinator.setFindNavigatorActive(isVisible, for: paneId)
            }
        ))
        #endif
        let replacesRegisteredTerminal = terminalSurfaceStore.register(terminal, for: paneId)
        #if os(iOS)
        terminal.acceptsTerminalInput = sessionState.paneState(for: paneId)?.connectionState.isConnected == true
        // A replacement is commonly registered before UIKit attaches it.
        // Publish that fact before reconciling its new identity so the
        // coordinator cannot spend an acquisition or repair off-window.
        keyboardCoordinator.setWindowAttached(terminal.isAttachedToWindow, for: paneId)
        if replacesRegisteredTerminal {
            keyboardCoordinator.terminalProviderIdentityDidChange(for: paneId)
        }
        Task { @MainActor [weak self, weak terminal] in
            guard let self, let terminal,
                  self.terminalSurfaceStore.isRegistered(terminal, for: paneId) else { return }
            self.keyboardCoordinator.setWindowAttached(
                terminal.isAttachedToWindow,
                for: paneId
            )
            self.publishTerminalInputAvailability(for: paneId)
            self.setTerminalFindNavigatorVisible(terminal.isFindNavigatorVisible, for: paneId)
            self.keyboardCoordinator.setFindNavigatorActive(
                terminal.isFindNavigatorVisible,
                for: paneId
            )
        }
        #endif
    }

    @discardableResult
    private func detachTerminalRegistration(
        for paneId: UUID
    ) -> (any TerminalSurface)? {
        terminalSurfaceStore.remove(for: paneId) { [self] terminal in
            prepareTerminalSurfaceRemoval(terminal, for: paneId)
        }
    }

    /// Unregister a dismantled platform view only if it is still the pane's
    /// registered terminal. SwiftUI may create its replacement before the old
    /// view's deferred teardown runs during window reconstruction.
    func unregisterTerminalSurface(
        _ terminal: any TerminalSurface,
        for paneId: UUID
    ) {
        terminalSurfaceStore.unregister(
            terminal,
            for: paneId,
            prepareForRemoval: { [self] current in
                prepareTerminalSurfaceRemoval(current, for: paneId)
            },
            cleanup: { $0.cleanup() }
        )
    }

    private func prepareTerminalSurfaceRemoval(
        _ terminal: any TerminalSurface,
        for paneId: UUID
    ) {
        #if os(iOS)
        terminal.setLifecycleCallbacks(nil)
        terminalFindNavigatorVisibleByPane.removeValue(forKey: paneId)
        terminalVoicePresentationByPane.removeValue(forKey: paneId)
        keyboardCoordinator.setWindowAttached(false, for: paneId)
        keyboardCoordinator.removePane(paneId)
        #endif
    }

    private func drainTerminalSurfaces() {
        terminalSurfaceStore.drain(
            prepareForRemoval: { [self] paneId, terminal in
                prepareTerminalSurfaceRemoval(terminal, for: paneId)
            },
            cleanup: { $0.cleanup() }
        )
    }

    #if os(iOS)
    private func setTerminalFindNavigatorVisible(_ isVisible: Bool, for paneId: UUID) {
        if terminalFindNavigatorVisibleByPane[paneId] != isVisible {
            terminalFindNavigatorVisibleByPane[paneId] = isVisible
        }
    }

    func terminalVoicePresentation(for paneId: UUID) -> TerminalVoicePresentationState {
        terminalVoicePresentationByPane[paneId] ?? .idle
    }

    func applyTerminalVoiceEvent(
        _ event: TerminalVoicePresentationState.Event,
        for paneId: UUID
    ) {
        let current = terminalVoicePresentation(for: paneId)
        let next = current.applying(event)
        guard next != current else { return }

        if next == .idle {
            terminalVoicePresentationByPane.removeValue(forKey: paneId)
        } else {
            terminalVoicePresentationByPane[paneId] = next
        }
    }
    #endif

    /// Register SSH shell for a pane
    @discardableResult
    func registerSSHClient(
        _ client: SSHClient,
        shellId: UUID,
        startToken: SSHShellRegistry.StartToken,
        for paneId: UUID,
        serverId: UUID,
        transportState: ShellTransportState = .ssh
    ) async -> Bool {
        let registerResult = transportRegistry.registerShell(
            client: client,
            shellId: shellId,
            startToken: startToken,
            for: paneId,
            serverId: serverId
        )

        switch registerResult {
        case .stale:
            logger.warning("Ignoring stale shell registration for pane \(paneId.uuidString, privacy: .public)")
            await performTrackedConnectionCleanup(for: client) {
                await client.closeShell(shellId)
            }
            return false
        case .accepted:
            logger.info(
                "Shell registered monotonic=\(Foundation.ProcessInfo.processInfo.systemUptime, privacy: .public) pane=\(paneId.uuidString, privacy: .public) start=\(startToken.id.uuidString, privacy: .public)"
            )
            break
        }

        setPaneTransport(transportState, for: paneId)
        return true
    }

    /// Unregister SSH shell
    func unregisterSSHClient(for paneId: UUID) async {
        await unregisterSSHClient(
            for: paneId,
            killingManagedTmuxSessionNamed: nil,
            beforeCleanup: nil
        )
    }

    func unregisterSSHClient(
        for paneId: UUID,
        ifOwnedBy client: SSHClient,
        shellId: UUID
    ) async {
        guard transportRegistry.ownsShell(
            client: client,
            shellId: shellId,
            for: paneId
        ) else { return }
        await unregisterSSHClient(for: paneId)
    }

    func unregisterSSHClient(
        for paneId: UUID,
        ifOwnedBy startToken: SSHShellRegistry.StartToken
    ) async {
        guard transportRegistry.ownsConnection(startToken: startToken, for: paneId) else { return }
        await unregisterSSHClient(for: paneId)
    }

    private func unregisterSSHClient(
        for paneId: UUID,
        killingManagedTmuxSessionNamed tmuxSessionName: String?,
        beforeCleanup: (@MainActor @Sendable () async -> Void)?
    ) async {
        transportRegistry.cancelConnectionTask(for: paneId)
        let unregisterResult = transportRegistry.unregisterShell(for: paneId)
        if let pendingStart = unregisterResult.pendingStart {
            tmuxResolver.cancelPrompt(
                requestId: pendingStart.token.id,
                setPrompt: setTmuxAttachPrompt
            )
        }

        guard let registration = unregisterResult.registration else {
            if let pendingStart = unregisterResult.pendingStart {
                if !transportRegistry.hasClientReferences(pendingStart.client) {
                    await performTrackedConnectionCleanup(for: pendingStart.client) {
                        if let beforeCleanup {
                            await beforeCleanup()
                        }
                        await pendingStart.client.disconnect()
                    }
                }
            }
            return
        }

        await performTrackedConnectionCleanup(for: registration.client) {
            if let beforeCleanup {
                await beforeCleanup()
            }
            if let tmuxSessionName {
                await self.dependencies.remoteTmux.killSession(
                    named: tmuxSessionName,
                    using: registration.client,
                    backend: nil
                )
            }
            if !self.transportRegistry.hasClientReferences(registration.client) {
                // Abort the whole session before its bounded shutdown. A last
                // shell does not need a separate channel-close handshake.
                await registration.client.disconnect()
            } else {
                await registration.client.closeShell(registration.shellId)
            }
        }

        setPaneTransport(.ssh, for: paneId)
    }

    private func performTrackedConnectionCleanup(
        for client: SSHClient,
        operation: @MainActor @Sendable @escaping () async -> Void
    ) async {
        await transportRegistry.performTrackedCleanup(
            for: client,
            operation: operation
        )
    }

    func activeSSHRoute(for paneId: UUID) -> (client: SSHClient, shellId: UUID)? {
        guard let route = transportRegistry.shellRoute(for: paneId) else { return nil }
        return (client: route.client, shellId: route.shellId)
    }

    func connectionOwnershipToken(for paneId: UUID) -> SSHShellRegistry.StartToken? {
        transportRegistry.connectionStartToken(for: paneId)
    }

    func hasLiveTransport(for paneId: UUID) -> Bool {
        transportRegistry.hasLiveTransport(for: paneId)
    }

    func eternalTerminalRuntime(
        for paneId: UUID,
        server: Server,
        credentials: ServerCredentials
    ) -> EternalTerminalRuntime {
        if let runtime = transportRegistry.runtime(for: paneId) {
            return runtime
        }
        let runtime = EternalTerminalRuntime(
            paneId: paneId,
            server: server,
            credentials: credentials,
            tabManager: self,
            dependencies: dependencies.eternalTerminalRuntime
        )
        _ = transportRegistry.runtime(for: paneId) { runtime }
        markEternalTerminalTransport(for: paneId)
        return runtime
    }

    func hasEternalTerminalRuntime(for paneId: UUID) -> Bool {
        transportRegistry.runtime(for: paneId) != nil
    }

    func sendEternalTerminalInput(_ data: Data, for paneId: UUID) {
        transportRegistry.runtime(for: paneId)?.send(data)
    }

    func resizeEternalTerminal(
        for paneId: UUID,
        cols: Int,
        rows: Int,
        pixelSize: TerminalPixelSize?
    ) {
        guard let runtime = transportRegistry.runtime(for: paneId) else { return }
        runtime.resize(cols: cols, rows: rows, pixelSize: pixelSize)
        runtime.startIfNeeded()
    }

    func isCurrentEternalTerminalRuntime(
        _ runtime: EternalTerminalRuntime,
        for paneId: UUID
    ) -> Bool {
        transportRegistry.isCurrentRuntime(runtime, for: paneId)
    }

    func isCurrentEternalTerminalRuntime(
        token: UUID,
        for paneId: UUID
    ) -> Bool {
        transportRegistry.runtime(for: paneId)?.identityToken == token
    }

    func markEternalTerminalTransport(for paneId: UUID) {
        setPaneTransport(.eternalTerminal, for: paneId)
    }

    func eternalTerminalTmuxResumeContext(
        for paneId: UUID
    ) -> EternalTerminalTmuxResumeContext? {
        sessionState.paneState(for: paneId)?.eternalTerminalTmuxResumeContext
    }

    func setEternalTerminalTmuxResumeContext(
        _ context: EternalTerminalTmuxResumeContext?,
        for paneId: UUID
    ) {
        guard sessionState.paneState(for: paneId)?.eternalTerminalTmuxResumeContext != context else { return }
        sessionState.updatePane(paneId, persist: true) {
            $0.eternalTerminalTmuxResumeContext = context
        }
    }

    func unregisterEternalTerminalRuntime(
        for paneId: UUID,
        killingManagedTmuxSessionNamed tmuxSessionName: String? = nil
    ) async {
        guard let runtime = transportRegistry.runtime(for: paneId),
              detachEternalTerminalRuntime(for: paneId, ifOwnedBy: runtime) else { return }
        if let tmuxSessionName {
            await runtime.killManagedTmuxSession(named: tmuxSessionName)
        }
        await runtime.close()
    }

    @discardableResult
    func detachEternalTerminalRuntime(
        for paneId: UUID,
        ifOwnedBy runtime: EternalTerminalRuntime
    ) -> Bool {
        guard transportRegistry.detachRuntime(runtime, for: paneId) else { return false }
        if sessionState.containsPane(paneId) {
            setPaneTransport(.ssh, for: paneId)
        }
        return true
    }

    func unregisterEternalTerminalRuntime(
        for paneId: UUID,
        ifOwnedBy runtime: EternalTerminalRuntime
    ) async {
        guard detachEternalTerminalRuntime(for: paneId, ifOwnedBy: runtime) else { return }
        await runtime.close()
    }

    func beginEternalTerminalNetworkRecoveryProbe(for paneId: UUID) async -> UUID? {
        await transportRegistry.runtime(for: paneId)?.beginNetworkRecoveryProbe()
    }

    func notifyEternalTerminalNetworkPathChanged(for paneId: UUID) {
        guard let runtime = transportRegistry.runtime(for: paneId) else { return }
        Task { await runtime.notifyNetworkPathChanged() }
    }

    func prepareEternalTerminalSessionsForApplicationBackground() async {
        await transportRegistry.forEachRuntime { runtime in
            await runtime.prepareForApplicationBackground()
        }
    }

    func resumeEternalTerminalSessionsFromApplicationBackground() async {
        await transportRegistry.forEachRuntime { runtime in
            await runtime.resumeFromApplicationBackground()
        }
    }

    func hasEternalTerminalCheckpoint(for paneId: UUID) -> Bool {
        eternalTerminalResumeStore.hasCheckpoint(for: paneId)
    }

    func hasMoshCheckpoint(for paneId: UUID) -> Bool {
        moshRecovery.hasCheckpoint(for: paneId)
    }

    func restoreMoshShell(
        for paneId: UUID,
        using client: SSHClient,
        cols: Int,
        rows: Int
    ) async -> ShellHandle? {
        await moshRecovery.restoreShell(
            for: paneId,
            using: client,
            cols: cols,
            rows: rows
        )
    }

    func persistMoshCheckpoint(
        for paneId: UUID,
        client: SSHClient,
        shellId: UUID
    ) async {
        await moshRecovery.persistCheckpoint(
            for: paneId,
            using: client,
            shellId: shellId
        )
    }

    func prepareResumableSessionsForApplicationBackground() async {
        await prepareEternalTerminalSessionsForApplicationBackground()

        let moshRoutes: [(paneId: UUID, client: SSHClient, shellId: UUID)] = sessionState.allPaneStates.compactMap { state in
            let paneId = state.paneId
            guard state.activeTransport == .mosh,
                  let route = transportRegistry.shellRoute(for: paneId) else {
                return nil
            }
            return (paneId: paneId, client: route.client, shellId: route.shellId)
        }
        for (paneId, client, shellId) in moshRoutes {
            await moshRecovery.prepareForApplicationBackground(
                for: paneId,
                using: client,
                shellId: shellId
            )
        }
    }

    func resumeResumableSessionsFromApplicationBackground() async {
        await resumeEternalTerminalSessionsFromApplicationBackground()

        let moshRoutes: [(paneId: UUID, client: SSHClient, shellId: UUID)] = sessionState.allPaneStates.compactMap { state in
            let paneId = state.paneId
            guard state.activeTransport == .mosh,
                  let route = transportRegistry.shellRoute(for: paneId) else {
                return nil
            }
            return (paneId: paneId, client: route.client, shellId: route.shellId)
        }
        for (paneId, client, shellId) in moshRoutes {
            await moshRecovery.resumeFromApplicationBackground(
                for: paneId,
                using: client,
                shellId: shellId
            )
        }
    }

    /// Returns a unique ownership token only for the first caller while no live shell exists.
    func beginShellStart(
        for paneId: UUID,
        client: SSHClient
    ) -> SSHShellRegistry.StartToken? {
        guard let serverId = sessionState.paneState(for: paneId)?.serverId else {
            return nil
        }

        let startResult = transportRegistry.beginShellStart(
            for: paneId,
            serverId: serverId,
            client: client
        )

        handleStaleShellStartContext(
            startResult.staleContext,
            logMessage: "Recovered stale pane shell-start lock for",
            paneId: paneId
        )
        return startResult.token
    }

    @discardableResult
    func startSSHConnectionTask(
        for paneId: UUID,
        server: Server,
        client: SSHClient,
        operation: @escaping @Sendable (TerminalSSHConnectionContext) async -> Void
    ) -> Bool {
        guard let startToken = beginShellStart(for: paneId, client: client) else {
            return false
        }

        let taskId = transportRegistry.startConnectionTask(for: paneId) { [weak self] taskId in
            guard let context = await self?.makeSSHConnectionContext(
                taskId: taskId,
                startToken: startToken,
                paneId: paneId,
                server: server,
                client: client
            ) else { return }
            await operation(context)
            await self?.finishShellStart(
                for: paneId,
                client: client,
                startToken: startToken
            )
        }
        guard taskId != nil else {
            finishShellStart(for: paneId, client: client, startToken: startToken)
            return false
        }
        return true
    }

    private func makeSSHConnectionContext(
        taskId: UUID,
        startToken: SSHShellRegistry.StartToken,
        paneId: UUID,
        server: Server,
        client: SSHClient
    ) -> TerminalSSHConnectionContext {
        let ownsConnection: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.transportRegistry.isCurrentConnectionTask(taskId: taskId, for: paneId)
                && self.isCurrentShellOwner(
                    for: paneId,
                    client: client,
                    startToken: startToken
                )
        }

        return TerminalSSHConnectionContext(
            isCurrent: ownsConnection,
            updateConnectionState: { [weak self] state in
                guard ownsConnection() else { return }
                self?.updatePaneState(paneId, connectionState: state)
            },
            startupPlan: { [weak self] in
                guard let self, ownsConnection() else { throw CancellationError() }
                return try await self.tmuxStartupPlan(
                    for: paneId,
                    serverId: server.id,
                    client: client,
                    startToken: startToken
                )
            },
            restoreMoshShell: { [weak self] cols, rows in
                guard let self, ownsConnection(), server.connectionMode == .mosh else {
                    return nil
                }
                return await self.restoreMoshShell(
                    for: paneId,
                    using: client,
                    cols: cols,
                    rows: rows
                )
            },
            registerShell: { [weak self] shell in
                guard let self, ownsConnection() else { return false }
                return await self.registerSSHClient(
                    client,
                    shellId: shell.id,
                    startToken: startToken,
                    for: paneId,
                    serverId: server.id,
                    transportState: shell.transportState
                )
            },
            persistMoshCheckpoint: { [weak self] shellId in
                guard let self, ownsConnection() else { return }
                await self.persistMoshCheckpoint(for: paneId, client: client, shellId: shellId)
            },
            updateTitle: { [weak self] title in
                guard ownsConnection() else { return }
                self?.updatePaneTitle(paneId, rawTitle: title)
            },
            hasOtherRegistrations: { [weak self] in
                guard let self, ownsConnection() else { return false }
                return self.hasOtherRegistrations(using: client, excluding: paneId)
            },
            handleShellEnd: { [weak self] shellId, reason in
                guard ownsConnection() else { return }
                self?.handleShellEnd(
                    for: paneId,
                    client: client,
                    shellId: shellId,
                    reason: reason
                )
            },
            handleFailure: { [weak self] error in
                guard ownsConnection() else { return }
                self?.handleConnectionFailure(for: paneId, error: error)
            },
            workingDirectory: { [weak self] in
                guard let self, ownsConnection(), self.shouldApplyWorkingDirectory(for: paneId) else {
                    return nil
                }
                return self.workingDirectory(for: paneId)
            }
        )
    }

    func finishShellStart(
        for paneId: UUID,
        client: SSHClient,
        startToken: SSHShellRegistry.StartToken
    ) {
        transportRegistry.finishShellStart(
            for: paneId,
            client: client,
            startToken: startToken
        )
    }

    func isTransportStartInFlight(for paneId: UUID) -> Bool {
        let result = transportRegistry.shellStartStatus(for: paneId)
        handleStaleShellStartContext(
            result.staleContext,
            logMessage: "Cleared stale pane shell-start in-flight flag for",
            paneId: paneId
        )
        return result.inFlight
            || transportRegistry.runtime(for: paneId)?.isStartInFlight == true
    }

    func isCurrentShellOwner(
        for paneId: UUID,
        client: SSHClient,
        startToken: SSHShellRegistry.StartToken
    ) -> Bool {
        sessionState.containsPane(paneId)
            && transportRegistry.ownsConnection(
                client: client,
                startToken: startToken,
                for: paneId
            )
    }

    private func preferredSSHClient(for serverId: UUID, allowPendingStart: Bool) -> SSHClient? {
        if let selectedTab = selectedTab(for: serverId) {
            let preferredPaneIds = [selectedTab.focusedPaneId, selectedTab.rootPaneId] + selectedTab.allPaneIds
            for paneId in preferredPaneIds {
                if let client = transportRegistry.registeredClient(for: paneId) {
                    return client
                }
            }
        }

        let serverTabs = tabs(for: serverId)
        for tab in serverTabs {
            for paneId in tab.allPaneIds {
                if let client = transportRegistry.registeredClient(for: paneId) {
                    return client
                }
            }
        }

        if let client = transportRegistry.firstRegisteredClient(for: serverId) {
            return client
        }

        if allowPendingStart, let client = transportRegistry.firstPendingClient(for: serverId) {
            return client
        }

        return nil
    }

    /// Returns the best-known client for this server, including pending shell starts.
    func sshClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: true)
    }

    /// Returns only clients that already have a registered shell for this server.
    func activeSSHClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: false)
    }

    func hasOtherActivePanes(for serverId: UUID, excluding paneId: UUID) -> Bool {
        sessionState.allPaneStates.contains { state in
            state.paneId != paneId && state.serverId == serverId && state.connectionState.isConnected
        }
    }

    /// Returns true when the same SSH client instance is registered to another live pane.
    /// This is used to avoid disconnecting a truly shared client during retry cleanup.
    func hasOtherRegistrations(using client: SSHClient, excluding paneId: UUID) -> Bool {
        transportRegistry.hasOtherClientReferences(using: client, excluding: paneId)
    }

    func sharedStatsClient(for serverId: UUID) -> SSHClient? {
        if selectedTransport(for: serverId) == .mosh {
            return nil
        }
        return sshClient(for: serverId)
    }

    private func selectedTransport(for serverId: UUID) -> ShellTransport {
        if let selectedTab = selectedTab(for: serverId),
           let state = sessionState.paneState(for: selectedTab.focusedPaneId) {
            return state.activeTransport
        }

        if let connectedPane = sessionState.paneStates(forServer: serverId)
            .first(where: { $0.connectionState.isConnected }) {
            return connectedPane.activeTransport
        }

        return sessionState.firstPaneState(for: serverId)?.activeTransport ?? .ssh
    }

    /// Clean up a pane (terminal + SSH)
    private func cleanupPane(
        _ paneId: UUID,
        removedPaneState: TerminalPaneState? = nil,
        intent: TerminalTeardownIntent = .explicitClose
    ) {
        guard intent.removesPersistedDescriptor else {
            assertionFailure("Application termination must preserve the pane descriptor")
            return
        }
        let tmuxSessionToKill = intent.terminatesManagedTmux
            ? (removedPaneState?.tmuxStatus ?? paneTmuxStatus(for: paneId))
                .flatMap { managedTmuxSessionNameToKill(for: paneId, status: $0) }
            : nil

        clearTmuxRuntimeState(for: paneId)
        reconnectCoordinator.invalidate(for: paneId)
        transportRegistry.cancelConnectionTask(for: paneId)
        terminalConnectionGenerations.removeValue(forKey: paneId)
        detachTerminalRegistration(for: paneId)
        runtimeTitleByPane.removeValue(forKey: paneId)
        titleOverrideByPane.removeValue(forKey: paneId)

        if intent.deletesResumableSessionState {
            do {
                try eternalTerminalResumeStore.deleteResumeState(for: paneId)
            } catch {
                logger.error("Failed to delete ET resume credentials: \(error.localizedDescription, privacy: .public)")
            }
            do {
                try moshRecovery.deleteCheckpoint(for: paneId)
            } catch {
                logger.error("Failed to delete Mosh recovery snapshot: \(error.localizedDescription, privacy: .public)")
            }
        }

        Task.detached { [weak self] in
            await self?.unregisterSSHClient(
                for: paneId,
                killingManagedTmuxSessionNamed: tmuxSessionToKill,
                beforeCleanup: nil
            )
            await self?.unregisterEternalTerminalRuntime(
                for: paneId,
                killingManagedTmuxSessionNamed: tmuxSessionToKill
            )
        }
    }

    // MARK: - Pane State

    #if os(iOS)
    private func publishTerminalInputAvailability(for paneId: UUID) {
        let connectionState = sessionState.paneState(for: paneId)?.connectionState ?? .idle
        let terminal = terminalSurfaceStore.surface(for: paneId)

        // Routing must be enabled before the coordinator can preserve or
        // reacquire the responder at the connected boundary.
        terminal?.acceptsTerminalInput = connectionState.isConnected
        keyboardCoordinator.setPaneInputEligible(
            TerminalKeyboardCoordinator.paneInputEligible(
                connectionState: connectionState,
                shouldRestoreOnReconnect: terminal?.shouldRestoreKeyboardFocusOnReconnect == true
            ),
            for: paneId
        )
    }
    #endif

    /// Update connection state for a pane
    func updatePaneState(_ paneId: UUID, connectionState: ConnectionState) {
        let clearedDisconnectReason = connectionState.isConnected
            && sessionState.paneState(for: paneId)?.disconnectReason != nil
        sessionState.updatePane(paneId, persist: clearedDisconnectReason) { paneState in
            paneState.connectionState = connectionState
            if connectionState.isConnected {
                paneState.disconnectReason = nil
                paneState.markConnectionEstablished()
            }
        }
        #if os(iOS)
        if connectionState.isConnecting,
           sessionState.paneState(for: paneId)?.hasEstablishedConnection == true,
           currentNetworkReadiness == .unavailable {
            queueIOSReconnectUntilNetworkReady(for: paneId)
        }
        #endif
        #if os(iOS)
        publishTerminalInputAvailability(for: paneId)
        #endif
        switch connectionState {
        case .connecting, .reconnecting:
            if sessionState.paneState(for: paneId)?.activeTransport != .eternalTerminal {
                setPaneTransport(.ssh, for: paneId)
            }
        case .disconnected, .failed:
            reconnectCoordinator.complete(for: paneId)
            setPanePresentationOverrides(.empty, for: paneId)
            terminalSurfaceStore.surface(for: paneId)?.applyPresentationOverrides(.empty)
            if paneTmuxStatus(for: paneId) == .foreground {
                setPaneTmuxStatus(.background, for: paneId)
            }
        case .connected:
            reconnectCoordinator.complete(for: paneId)
            dependencies.effects.recordSuccessfulConnection(
                paneId,
                sessionState.paneState(for: paneId)?.activeTransport.rawValue
                    ?? ShellTransport.ssh.rawValue
            )
        case .idle:
            reconnectCoordinator.complete(for: paneId)
        }
    }

    func handleConnectionFailure(for paneId: UUID, error: Error) {
        let requiresUserAction = (error as? SSHError).map {
            !$0.allowsAutomaticReconnectRetry
        } ?? false
        if requiresUserAction, sessionState.paneState(for: paneId)?.disconnectReason != nil {
            sessionState.updatePane(paneId, persist: true) { $0.disconnectReason = nil }
        }
        updatePaneState(paneId, connectionState: .failed(error.localizedDescription))
    }

    func handleShellEnd(
        for paneId: UUID,
        client: SSHClient,
        shellId: UUID,
        reason: TerminalShellEndReason
    ) {
        guard transportRegistry.ownsShell(client: client, shellId: shellId, for: paneId) else {
            logger.info("Ignoring stale shell end for pane \(paneId.uuidString, privacy: .public)")
            return
        }
        handleShellEnd(
            for: paneId,
            reason: reason,
            unregistering: (client, shellId)
        )
    }

    func handleShellEnd(for paneId: UUID, reason: TerminalShellEndReason) {
        handleShellEnd(for: paneId, reason: reason, unregistering: nil)
    }

    private func handleShellEnd(
        for paneId: UUID,
        reason: TerminalShellEndReason,
        unregistering ownership: (client: SSHClient, shellId: UUID)?
    ) {
        guard let paneState = sessionState.paneState(for: paneId) else { return }

        switch reason {
        case .tmuxEnded(.managed):
            guard let tab = tabs(for: paneState.serverId).first(where: { $0.id == paneState.tabId }) else {
                return
            }
            closePane(tab: tab, paneId: paneId, intent: .remoteSessionEnded)
            return

        case .tmuxDetached(let ownership):
            if ownership == .managed {
                tmuxResolver.confirmManagedSession(for: paneId)
            }
            sessionState.updatePane(paneId, persist: true) { $0.disconnectReason = .tmuxDetached }
            updatePaneState(paneId, connectionState: .disconnected)

        case .tmuxCreationFailed:
            tmuxResolver.clearAttachmentState(for: paneId)
            sessionState.updatePane(paneId, persist: true) { $0.disconnectReason = nil }
            updatePaneTmuxStatus(paneId, status: .unknown)
            updatePaneState(
                paneId,
                connectionState: .failed(String(localized: "Unable to start tmux session."))
            )

        case .tmuxEnded(.external):
            sessionState.updatePane(paneId, persist: true) { $0.disconnectReason = .externalTmuxEnded }
            updatePaneState(paneId, connectionState: .disconnected)

        case .transportEnded:
            sessionState.updatePane(paneId) { $0.disconnectReason = .transportEnded }
            updatePaneState(paneId, connectionState: .disconnected)
        }

        Task { [weak self, ownership] in
            guard let self else { return }
            if let ownership {
                await self.unregisterSSHClient(
                    for: paneId,
                    ifOwnedBy: ownership.client,
                    shellId: ownership.shellId
                )
            } else {
                await self.unregisterSSHClient(for: paneId)
            }
        }
    }

    private var hasConnectedPanes: Bool {
        sessionState.hasConnectedPanes
    }

    func updatePaneWorkingDirectory(_ paneId: UUID, rawDirectory: String) {
        guard let normalized = normalizeWorkingDirectory(rawDirectory) else { return }
        setPaneWorkingDirectory(normalized, for: paneId)
    }

    func updatePaneTitle(_ paneId: UUID, rawTitle: String) {
        guard sessionState.containsPane(paneId) else { return }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        setPaneTitle(title, for: paneId)
    }

    func setPaneTitleOverride(_ rawTitle: String?, for paneId: UUID) {
        guard sessionState.containsPane(paneId) else { return }
        let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty {
            titleOverrideByPane.removeValue(forKey: paneId)
        } else {
            titleOverrideByPane[paneId] = title
        }
    }

    func displayTitle(forPane paneId: UUID, fallback: String? = nil) -> String? {
        titleOverrideByPane[paneId] ?? runtimeTitleByPane[paneId] ?? fallback
    }

    func presentationOverrides(for paneId: UUID) -> TerminalPresentationOverrides {
        sessionState.paneState(for: paneId)?.presentationOverrides ?? .empty
    }

    func handleTerminalZoom(_ action: TerminalZoomAction, for paneId: UUID) -> TerminalZoomResult? {
        guard sessionState.containsPane(paneId) else { return nil }

        let currentOverrides = presentationOverrides(for: paneId)
        let overrides = currentOverrides.applyingZoom(action)
        guard overrides != currentOverrides else {
            return TerminalZoomResult(
                presentationOverrides: currentOverrides,
                effectiveFontSize: currentOverrides.resolvedFontSize()
            )
        }
        setPanePresentationOverrides(overrides, for: paneId)
        sessionState.requestPersistence()
        terminalSurfaceStore.surface(for: paneId)?.applyPresentationOverrides(overrides)
        return TerminalZoomResult(
            presentationOverrides: overrides,
            effectiveFontSize: overrides.resolvedFontSize()
        )
    }

    func displayTitle(for tab: TerminalTab) -> String {
        titleOverrideByPane[tab.focusedPaneId]
            ?? runtimeTitleByPane[tab.focusedPaneId]
            ?? titleOverrideByPane[tab.rootPaneId]
            ?? runtimeTitleByPane[tab.rootPaneId]
            ?? tab.title
    }

    func workingDirectory(for paneId: UUID) -> String? {
        paneWorkingDirectory(for: paneId)
    }

    func shouldApplyWorkingDirectory(for paneId: UUID) -> Bool {
        guard let status = paneTmuxStatus(for: paneId) else { return false }
        return status == .off || status == .missing
    }

    func updatePaneTmuxStatus(_ paneId: UUID, status: TmuxStatus) {
        setPaneTmuxStatus(status, for: paneId)
    }

    // MARK: - tmux Integration

    private func setTmuxAttachPrompt(_ prompt: TmuxAttachPrompt?) {
        tmuxAttachPrompt = prompt
    }

    private func clearTmuxRuntimeState(for paneId: UUID) {
        tmuxResolver.clearRuntimeState(for: paneId, setPrompt: setTmuxAttachPrompt)
    }

    func resolveTmuxAttachPrompt(requestId: UUID, selection: TmuxAttachSelection) {
        tmuxResolver.resolvePrompt(
            requestId: requestId,
            selection: selection,
            setPrompt: setTmuxAttachPrompt
        )
    }

    func cancelTmuxAttachPrompt(requestId: UUID) {
        tmuxResolver.cancelPrompt(requestId: requestId, setPrompt: setTmuxAttachPrompt)
    }

    private func managedTmuxSessionNames(for serverId: UUID) -> Set<String> {
        var names: Set<String> = []
        for tab in tabs(for: serverId) {
            for paneId in tab.allPaneIds {
                let ownership = tmuxResolver.sessionOwnership[paneId] ?? .managed
                guard ownership == .managed else { continue }
                names.insert(tmuxResolver.sessionName(for: paneId))
            }
        }
        return names
    }

    private func tmuxSessionNamesToKeep(
        for serverId: UUID,
        paneId: UUID,
        selection: TmuxAttachSelection
    ) -> Set<String> {
        var names = managedTmuxSessionNames(for: serverId)
        switch selection {
        case .skipTmux:
            break
        case .createManaged:
            names.insert(tmuxResolver.sessionName(for: paneId))
        case .attachExisting(let sessionName):
            names.insert(sessionName)
        }
        return names
    }

    private func currentTmuxStatus(for paneId: UUID, serverId: UUID) -> TmuxStatus {
        guard let tab = selectedTab(for: serverId) else { return .background }
        return (tab.id == sessionState.selectedTabId(for: serverId) && tab.focusedPaneId == paneId)
            ? .foreground
            : .background
    }

    private func disableTmuxAttachment(for paneId: UUID, status: TmuxStatus) {
        tmuxResolver.clearAttachmentState(for: paneId)
        updatePaneTmuxStatus(paneId, status: status)
    }

    private func runTmuxCleanupIfNeeded(
        for serverId: UUID,
        paneId: UUID,
        selection: TmuxAttachSelection,
        using client: SSHClient,
        backend: RemoteTmuxBackend
    ) async {
        guard tmuxCleanupServers.insert(serverId).inserted else { return }
        await dependencies.remoteTmux.cleanupLegacySessions(
            using: client,
            backend: backend
        )
        await dependencies.remoteTmux.cleanupDetachedSessions(
            deviceId: dependencies.tmuxConfiguration.deviceID,
            keeping: tmuxSessionNamesToKeep(
                for: serverId,
                paneId: paneId,
                selection: selection
            ),
            using: client,
            backend: backend
        )
    }

    private func prepareActiveTmuxPane(
        for paneId: UUID,
        serverId: UUID,
        using client: SSHClient,
        backend: RemoteTmuxBackend
    ) async {
        updatePaneTmuxStatus(paneId, status: currentTmuxStatus(for: paneId, serverId: serverId))
        let terminalType = await client.remoteTerminalType()
        await dependencies.remoteTmux.prepareConfig(
            using: client,
            terminalType: terminalType,
            themeStyle: currentRemoteTmuxThemeStyle(),
            backend: backend
        )
    }

    private func tmuxStartupCommand(
        for paneId: UUID,
        selection: TmuxAttachSelection,
        workingDirectory: String,
        backend: RemoteTmuxBackend,
        lifecycleMarkerToken: String,
        ownership: TmuxSessionOwnership,
        reattachingManagedSession: Bool,
        transport: ShellTransport
    ) -> String? {
        let themeStyle = currentRemoteTmuxThemeStyle()
        switch selection {
        case .skipTmux:
            return nil
        case .createManaged:
            if reattachingManagedSession {
                return RemoteTmuxCommandBuilder.attachExistingCommand(
                    themeStyle: themeStyle,
                    sessionName: tmuxResolver.sessionName(for: paneId),
                    ownership: .managed,
                    backend: backend,
                    lifecycleMarkerToken: lifecycleMarkerToken,
                    transport: transport
                )
            }
            return RemoteTmuxCommandBuilder.attachCommand(
                themeStyle: themeStyle,
                sessionName: tmuxResolver.sessionName(for: paneId),
                workingDirectory: workingDirectory,
                backend: backend,
                lifecycleMarkerToken: lifecycleMarkerToken,
                transport: transport
            )
        case .attachExisting(let sessionName):
            return RemoteTmuxCommandBuilder.attachExistingCommand(
                themeStyle: themeStyle,
                sessionName: sessionName,
                ownership: ownership,
                backend: backend,
                lifecycleMarkerToken: lifecycleMarkerToken,
                transport: transport
            )
        }
    }

    private func currentRemoteTmuxThemeStyle() -> RemoteTmuxThemeStyle {
        dependencies.tmuxConfiguration.themeStyle()
    }

    nonisolated static func remoteTmuxThemeStyle(
        for storedName: String?
    ) -> RemoteTmuxThemeStyle {
        let name = (try? TerminalThemeValidator.validateAndNormalizeThemeName(
            storedName ?? "Aizen Dark"
        )) ?? "Aizen Dark"
        return RemoteTmuxThemeStyle(
            name: name,
            modeStyle: ThemeColorParser.tmuxModeStyle(for: name)
        )
    }

    func shouldReattachManagedTmuxSession(for paneId: UUID) -> Bool {
        tmuxResolver.sessionOwnership[paneId] == .managed
            && tmuxResolver.sessionNames[paneId] != nil
            && tmuxResolver.hasConfirmedManagedSession(for: paneId)
    }

    private func resolveTmuxWorkingDirectory(
        for paneId: UUID,
        using client: SSHClient,
        backend: RemoteTmuxBackend? = nil
    ) async -> String {
        if let seedPaneId = sessionState.paneState(for: paneId)?.seedPaneId,
           let path = await dependencies.remoteTmux.currentPath(
               sessionName: tmuxResolver.sessionName(for: seedPaneId),
               using: client,
               backend: backend
           ) {
            return path
        }

        if let path = await dependencies.remoteTmux.currentPath(
            sessionName: tmuxResolver.sessionName(for: paneId),
            using: client,
            backend: backend
        ) {
            return path
        }

        if let candidate = paneWorkingDirectory(for: paneId)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !candidate.isEmpty {
            return candidate
        }

        return "~"
    }

    private func normalizeWorkingDirectory(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized: String
        if let schemeRange = trimmed.range(of: "://") {
            let afterScheme = trimmed[schemeRange.upperBound...]
            guard let pathStart = afterScheme.firstIndex(of: "/") else { return nil }
            let path = String(afterScheme[pathStart...])
            normalized = path.removingPercentEncoding ?? path
        } else {
            normalized = trimmed
        }

        guard normalized.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return normalized
    }

    private func updateTmuxSelectionStatuses(selectedTabs: [UUID: UUID]) {
        for serverId in sessionState.serverIdsWithTabs {
            let tabsForServer = tabs(for: serverId)
            for tab in tabsForServer {
                updateTmuxFocus(
                    for: tab,
                    isSelectedTab: selectedTabs[serverId] == tab.id
                )
            }
        }
    }

    private func updateTmuxFocus(for tab: TerminalTab) {
        updateTmuxFocus(
            for: tab,
            isSelectedTab: sessionState.selectedTabId(for: tab.serverId) == tab.id
        )
    }

    private func updateTmuxFocus(for tab: TerminalTab, isSelectedTab: Bool) {
        for paneId in tab.allPaneIds {
            guard let state = sessionState.paneState(for: paneId) else { continue }
            guard state.tmuxStatus == .foreground || state.tmuxStatus == .background else { continue }
            let newStatus: TmuxStatus = (isSelectedTab && tab.focusedPaneId == paneId) ? .foreground : .background
            if state.tmuxStatus != newStatus {
                setPaneTmuxStatus(newStatus, for: paneId)
            }
        }
    }

    func tmuxStartupPlan(
        for paneId: UUID,
        serverId: UUID,
        client: SSHClient,
        startToken: SSHShellRegistry.StartToken
    ) async throws -> TerminalShellStartupPlan {
        try await tmuxStartupPlan(
            for: paneId,
            serverId: serverId,
            client: client,
            startToken: startToken,
            availabilityResolver: {
                await dependencies.remoteTmux.tmuxAvailability(using: client)
            }
        )
    }

    func tmuxStartupPlan(
        for paneId: UUID,
        serverId: UUID,
        client: SSHClient,
        startToken: SSHShellRegistry.StartToken,
        availabilityResolver: () async -> RemoteTmuxAvailability,
        transport: ShellTransport = .ssh
    ) async throws -> TerminalShellStartupPlan {
        try await tmuxStartupPlan(
            for: paneId,
            serverId: serverId,
            client: client,
            availabilityResolver: availabilityResolver,
            transport: transport,
            requestId: startToken.id,
            validateOwner: {
                try self.requireCurrentShellOwner(
                    for: paneId,
                    client: client,
                    startToken: startToken
                )
            }
        )
    }

    func eternalTerminalTmuxStartupPlan(
        for paneId: UUID,
        serverId: UUID,
        client: SSHClient,
        runtimeToken: UUID
    ) async throws -> TerminalShellStartupPlan {
        let plan = try await tmuxStartupPlan(
            for: paneId,
            serverId: serverId,
            client: client,
            availabilityResolver: {
                await dependencies.remoteTmux.tmuxAvailability(using: client)
            },
            transport: .eternalTerminal,
            requestId: runtimeToken,
            validateOwner: {
                try Task.checkCancellation()
                guard self.isCurrentEternalTerminalRuntime(token: runtimeToken, for: paneId) else {
                    throw CancellationError()
                }
            }
        )
        if let command = plan.command, plan.tmuxLifecycle != nil {
            try Task.checkCancellation()
            guard isCurrentEternalTerminalRuntime(token: runtimeToken, for: paneId) else {
                throw CancellationError()
            }

            let remotePath = EternalTerminalStartupCommand.remoteScriptPath(token: runtimeToken)
            let script = EternalTerminalStartupCommand.script(
                command: command,
                remotePath: remotePath
            )
            try await client.upload(
                Data(script.utf8),
                to: remotePath,
                permissions: 0o700
            )
            return TerminalShellStartupPlan(
                command: EternalTerminalStartupCommand.invocation(remotePath: remotePath),
                tmuxLifecycle: plan.tmuxLifecycle
            )
        }

        guard plan.command == nil,
              let workingDirectory = paneWorkingDirectory(for: paneId),
              !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return plan
        }

        let environment = await client.remoteEnvironment()
        let restorePlan = RemoteTerminalBootstrap.workingDirectoryRestorePlan(
            for: workingDirectory,
            environment: environment
        )
        guard case .command(let command) = restorePlan else {
            if case .keepDefault(let reason) = restorePlan {
                logger.warning(
                    "Keeping the default ET directory [reason: \(reason.rawValue, privacy: .public)]"
                )
            }
            return plan
        }
        return TerminalShellStartupPlan(
            command: command,
            tmuxLifecycle: nil
        )
    }

    private func tmuxStartupPlan(
        for paneId: UUID,
        serverId: UUID,
        client: SSHClient,
        availabilityResolver: () async -> RemoteTmuxAvailability,
        transport: ShellTransport,
        requestId: UUID,
        validateOwner: () throws -> Void
    ) async throws -> TerminalShellStartupPlan {
        try validateOwner()

        guard tmuxResolver.isTmuxEnabled(for: serverId) else {
            disableTmuxAttachment(for: paneId, status: .off)
            return .plainShell
        }

        let availability = await availabilityResolver()
        try validateOwner()

        let backend: RemoteTmuxBackend
        switch availability {
        case .unsupported:
            disableTmuxAttachment(for: paneId, status: .off)
            return .plainShell
        case .available(let availableBackend):
            backend = availableBackend
        case .confirmedMissing:
            disableTmuxAttachment(for: paneId, status: .missing)
            return .plainShell
        case .indeterminate(let failure):
            logger.warning(
                "Preserving tmux attachment for pane \(paneId.uuidString, privacy: .public) after indeterminate probe: \(failure.logDescription, privacy: .public)"
            )
            throw failure.retryError
        }

        let isReattachingManagedSession = shouldReattachManagedTmuxSession(for: paneId)
        let selection = try await tmuxResolver.resolveSelection(
            for: paneId,
            serverId: serverId,
            client: client,
            backend: backend,
            requestId: requestId,
            validateOwner: {
                try validateOwner()
            },
            setPrompt: setTmuxAttachPrompt
        )
        try validateOwner()
        tmuxResolver.updateAttachmentState(for: paneId, selection: selection, setPrompt: setTmuxAttachPrompt)
        sessionState.requestPersistence()

        if case .skipTmux = selection {
            updatePaneTmuxStatus(paneId, status: .off)
            return .plainShell
        }

        await runTmuxCleanupIfNeeded(
            for: serverId,
            paneId: paneId,
            selection: selection,
            using: client,
            backend: backend
        )
        try validateOwner()
        await prepareActiveTmuxPane(for: paneId, serverId: serverId, using: client, backend: backend)
        try validateOwner()

        let workingDirectory = await resolveTmuxWorkingDirectory(
            for: paneId,
            using: client,
            backend: backend
        )
        try validateOwner()
        if workingDirectory != "~" {
            setPaneWorkingDirectory(workingDirectory, for: paneId)
        }
        guard let ownership = tmuxResolver.sessionOwnership[paneId] else {
            throw SSHError.unknown("tmux attachment state was lost during startup")
        }
        let lifecycleMarkerToken = UUID().uuidString
        let sessionName = tmuxResolver.sessionName(for: paneId)
        let presenceToken = UUID().uuidString
        let existsMarker = "__VVTERM_TMUX_EXISTS_\(presenceToken)__"
        let missingMarker = "__VVTERM_TMUX_MISSING_\(presenceToken)__"
        return TerminalShellStartupPlan(
            command: tmuxStartupCommand(
                for: paneId,
                selection: selection,
                workingDirectory: workingDirectory,
                backend: backend,
                lifecycleMarkerToken: lifecycleMarkerToken,
                ownership: ownership,
                reattachingManagedSession: isReattachingManagedSession,
                transport: transport
            ),
            tmuxLifecycle: TmuxShellLifecycleContext(
                ownership: ownership,
                markerToken: lifecycleMarkerToken,
                presenceProbe: TmuxSessionPresenceProbe(
                    command: RemoteTmuxCommandBuilder.sessionPresenceProbeCommand(
                        sessionName: sessionName,
                        backend: backend,
                        existsMarker: existsMarker,
                        missingMarker: missingMarker
                    ),
                    existsMarker: existsMarker,
                    missingMarker: missingMarker
                )
            )
        )
    }

    private func requireCurrentShellOwner(
        for paneId: UUID,
        client: SSHClient,
        startToken: SSHShellRegistry.StartToken
    ) throws {
        try Task.checkCancellation()
        guard isCurrentShellOwner(
            for: paneId,
            client: client,
            startToken: startToken
        ) else {
            logger.info("Ignoring stale tmux startup result for pane \(paneId.uuidString, privacy: .public)")
            throw CancellationError()
        }
    }

    func startTmuxInstall(
        for paneId: UUID,
        onInstalled: @MainActor @escaping () -> Void
    ) async {
        if let runtime = transportRegistry.runtime(for: paneId) {
            await startEternalTerminalTmuxInstall(
                for: paneId,
                runtime: runtime,
                onInstalled: onInstalled
            )
            return
        }

        guard let registration = transportRegistry.shellRegistration(for: paneId) else { return }
        let serverId = registration.serverId
        guard tmuxResolver.isTmuxEnabled(for: serverId) else { return }

        updatePaneTmuxStatus(paneId, status: .installing)
        do {
            let outcome = try await performTmuxInstall(
                for: paneId,
                using: registration.client,
                sendScript: { script in
                    try await self.dependencies.remoteTmux.sendScript(
                        script,
                        using: registration.client,
                        shellId: registration.shellId
                    )
                },
                validateOwner: {
                    self.transportRegistry.ownsShell(
                        client: registration.client,
                        shellId: registration.shellId,
                        for: paneId
                    )
                }
            )
            guard transportRegistry.ownsShell(
                client: registration.client,
                shellId: registration.shellId,
                for: paneId
            ) else { return }
            await finishTmuxInstall(
                outcome,
                for: paneId,
                onInstalled: onInstalled,
                beforeReconnect: {
                    await self.unregisterSSHClient(
                        for: paneId,
                        ifOwnedBy: registration.client,
                        shellId: registration.shellId
                    )
                }
            )
        } catch is CancellationError {
            return
        } catch {
            guard transportRegistry.ownsShell(
                client: registration.client,
                shellId: registration.shellId,
                for: paneId
            ) else { return }
            logger.warning("tmux installation failed: \(error.localizedDescription, privacy: .public)")
            updatePaneTmuxStatus(paneId, status: .unknown)
        }
    }

    private func startEternalTerminalTmuxInstall(
        for paneId: UUID,
        runtime: EternalTerminalRuntime,
        onInstalled: @MainActor @escaping () -> Void
    ) async {
        guard let serverId = sessionState.paneState(for: paneId)?.serverId,
              tmuxResolver.isTmuxEnabled(for: serverId),
              isCurrentEternalTerminalRuntime(runtime, for: paneId) else { return }

        updatePaneTmuxStatus(paneId, status: .installing)
        do {
            let outcome = try await runtime.withBootstrapSSHClient { client in
                try await self.performTmuxInstall(
                    for: paneId,
                    using: client,
                    sendScript: { script in
                        try await runtime.sendInteractiveScript(script)
                    },
                    validateOwner: {
                        self.isCurrentEternalTerminalRuntime(runtime, for: paneId)
                    }
                )
            }
            guard isCurrentEternalTerminalRuntime(runtime, for: paneId) else { return }
            await finishTmuxInstall(
                outcome,
                for: paneId,
                onInstalled: onInstalled,
                beforeReconnect: {
                    await self.unregisterEternalTerminalRuntime(for: paneId)
                }
            )
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentEternalTerminalRuntime(runtime, for: paneId) else { return }
            logger.warning("ET tmux installation failed: \(error.localizedDescription, privacy: .public)")
            updatePaneTmuxStatus(paneId, status: .unknown)
        }
    }

    private func performTmuxInstall(
        for paneId: UUID,
        using client: SSHClient,
        sendScript: @MainActor @Sendable (String) async throws -> Void,
        validateOwner: @MainActor @Sendable () -> Bool
    ) async throws -> TmuxInstallOutcome {
        guard let backend = await dependencies.remoteTmux.tmuxInstallBackend(
            using: client
        ) else {
            return .unavailable
        }
        try Task.checkCancellation()
        guard validateOwner() else { throw CancellationError() }

        let sessionName = tmuxResolver.sessionName(for: paneId)
        let workingDirectory = await resolveTmuxWorkingDirectory(
            for: paneId,
            using: client,
            backend: backend
        )
        try Task.checkCancellation()
        guard validateOwner() else { throw CancellationError() }

        let terminalType = await client.remoteTerminalType()
        try Task.checkCancellation()
        guard validateOwner() else { throw CancellationError() }

        let script = RemoteTmuxCommandBuilder.installAndAttachScript(
            themeStyle: currentRemoteTmuxThemeStyle(),
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            terminalType: terminalType,
            backend: backend,
            attachAfterInstall: false
        )
        try await sendScript(script)

        var observedIndeterminateResult = false
        for _ in 0..<6 {
            try await Task.sleep(for: .seconds(2))
            guard validateOwner() else { throw CancellationError() }
            let availability = await dependencies.remoteTmux.tmuxAvailability(
                using: client
            )
            try Task.checkCancellation()
            guard validateOwner() else { throw CancellationError() }

            switch availability {
            case .available:
                return .installed(sessionName: sessionName)
            case .confirmedMissing:
                continue
            case .indeterminate:
                observedIndeterminateResult = true
            case .unsupported:
                return .unavailable
            }
        }
        return observedIndeterminateResult ? .indeterminate : .missing
    }

    private func finishTmuxInstall(
        _ outcome: TmuxInstallOutcome,
        for paneId: UUID,
        onInstalled: @MainActor @escaping () -> Void,
        beforeReconnect: @MainActor @Sendable () async -> Void
    ) async {
        switch outcome {
        case .installed(let sessionName):
            await beforeReconnect()
            completeTmuxInstall(
                for: paneId,
                sessionName: sessionName,
                onInstalled: onInstalled
            )
        case .unavailable:
            updatePaneTmuxStatus(paneId, status: .off)
        case .missing:
            updatePaneTmuxStatus(paneId, status: .missing)
        case .indeterminate:
            updatePaneTmuxStatus(paneId, status: .unknown)
        }
    }

    func completeTmuxInstall(
        for paneId: UUID,
        sessionName: String,
        onInstalled: () -> Void
    ) {
        guard sessionState.containsPane(paneId) else { return }
        tmuxResolver.clearAttachmentState(for: paneId)
        tmuxResolver.sessionNames[paneId] = sessionName
        tmuxResolver.sessionOwnership[paneId] = .managed
        sessionState.requestPersistence()
        onInstalled()
    }

    func installMoshServer(for paneId: UUID) async throws {
        guard let registration = transportRegistry.shellRegistration(for: paneId) else {
            throw SSHError.notConnected
        }
        try await dependencies.remoteMosh.installMoshServer(
            using: registration.client
        )
    }

    private func managedTmuxSessionNameToKill(for paneId: UUID, status: TmuxStatus) -> String? {
        guard status == .foreground || status == .background || status == .installing else { return nil }
        let ownership = tmuxResolver.sessionOwnership[paneId] ?? .managed
        guard ownership == .managed else { return nil }
        return tmuxResolver.sessionName(for: paneId)
    }

    func killTmuxIfNeeded(for paneId: UUID) {
        guard let registration = transportRegistry.shellRegistration(for: paneId) else { return }
        let ownership = tmuxResolver.sessionOwnership[paneId] ?? .managed
        guard ownership == .managed else { return }

        let sessionName = tmuxResolver.sessionName(for: paneId)
        Task.detached {
            [client = registration.client, remoteTmux = dependencies.remoteTmux, sessionName] in
            await remoteTmux.killSession(
                named: sessionName,
                using: client,
                backend: nil
            )
        }
    }

    func disableTmux(for serverId: UUID) {
        for state in sessionState.paneStates(forServer: serverId) {
            setPaneTmuxStatus(.off, for: state.paneId)
            clearTmuxRuntimeState(for: state.paneId)
        }
    }

}

#if DEBUG
extension TerminalTabManager {
    func setEternalTerminalResumeStoreForTesting(
        _ store: any EternalTerminalResumeStoring
    ) {
        eternalTerminalResumeStore = store
    }

    func persistAndRestoreSnapshotForTesting() {
        sessionState.persistAndRestoreSnapshotForTesting()
    }

    func snapshotDataForTesting() throws -> Data {
        try sessionState.snapshotDataForTesting()
    }

    func installTabForTesting(
        _ tab: TerminalTab,
        paneState: TerminalPaneState,
        select: Bool = true
    ) {
        sessionState.install(tab, paneState: paneState, select: select)
    }

    func setPaneStateForTesting(_ paneState: TerminalPaneState) {
        sessionState.setPaneState(paneState)
    }

    func updatePaneForTesting(
        _ paneId: UUID,
        _ mutation: (inout TerminalPaneState) -> Void
    ) {
        sessionState.updatePane(paneId, mutation)
    }

    var allPaneStatesForTesting: [TerminalPaneState] {
        sessionState.allPaneStates
    }

    /// Resets manager state for deterministic integration tests.
    func resetForTesting() async {
        let allPaneIds = sessionState.paneIds
            .union(transportRegistry.ownedPaneIds)
        for paneId in allPaneIds {
            clearTmuxRuntimeState(for: paneId)
        }
        let drainedTransports = transportRegistry.drain()
        sessionState.resetForTesting()
        splitZoomedTabIds = []
        runtimeTitleByPane = [:]
        titleOverrideByPane = [:]
        #if os(iOS)
        terminalFindNavigatorVisibleByPane = [:]
        terminalVoicePresentationByPane = [:]
        keyboardCoordinator.setActivePane(nil)
        keyboardCoordinator.setViewActive(false)
        #endif
        tmuxAttachPrompt = nil
        drainTerminalSurfaces()
        reconnectCoordinator.invalidateAll()
        terminalConnectionGenerations.removeAll()
        #if os(macOS)
        macRecoveryTask?.cancel()
        macRecoveryTask = nil
        activeMacRecoveryGeneration = nil
        activeMacRecoveryReconciliationID = nil
        macRecoveryGate = MacTerminalRecoveryGate()
        #elseif os(iOS)
        iosNetworkRecoveryGate = TerminalNetworkRecoveryGate()
        #endif
        tabOpensInFlight.removeAll()
        tmuxCleanupServers.removeAll()
        eternalTerminalResumeStore = defaultEternalTerminalResumeStore
        for client in drainedTransports.clients {
            await client.disconnect()
        }
        for runtime in drainedTransports.runtimes {
            await runtime.close()
        }
    }
}
#endif
