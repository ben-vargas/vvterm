import Combine
import Foundation
import os.log

@MainActor
struct TerminalRemoteSessionShellRegistration {
    let client: SSHClient
    let shellID: UUID
    let serverID: UUID
}

/// Owns persistent remote-session selection, launch, cleanup, and termination.
@MainActor
final class TerminalRemoteSessionCoordinator: ObservableObject {
    struct CleanupKey: Hashable {
        let serverID: UUID
        let backendIdentifier: RemoteSessionBackendIdentifier
    }

    var attachPrompt: RemoteSessionAttachPrompt? {
        resolver.currentPrompt
    }

    var backendMetadata: [RemoteSessionBackendMetadata] {
        remoteSessions.backendMetadata
    }

    let configuration: TerminalRemoteSessionConfiguration
    let remoteSessions: any TerminalRemoteSessionServicing
    let resolver: RemoteSessionAttachResolver
    let sessionState: TerminalSessionStateStore
    let transportLifetime: TerminalTransportLifetime
    let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VVTerm",
        category: "TerminalRemoteSessionCoordinator"
    )
    var completedCleanup: Set<CleanupKey> = []
    private var cancellables: Set<AnyCancellable> = []

    init(
        configuration: TerminalRemoteSessionConfiguration,
        remoteSessions: any TerminalRemoteSessionServicing,
        resolver: RemoteSessionAttachResolver,
        sessionState: TerminalSessionStateStore,
        transportLifetime: TerminalTransportLifetime
    ) {
        self.configuration = configuration
        self.remoteSessions = remoteSessions
        self.resolver = resolver
        self.sessionState = sessionState
        self.transportLifetime = transportLifetime
        resolver.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Settings and attachment state

    func isEnabled(for serverID: UUID) -> Bool {
        resolver.isEnabled(for: serverID)
    }

    func backendIdentifier(for serverID: UUID) -> RemoteSessionBackendIdentifier {
        resolver.backendIdentifier(for: serverID)
    }

    func attachment(for paneID: UUID) -> TerminalRemoteSessionAttachmentState? {
        resolver.attachment(for: paneID)
    }

    func setAttachment(
        for paneID: UUID,
        identifier: RemoteSessionIdentifier,
        ownership: RemoteSessionOwnership,
        managedSessionConfirmed: Bool = false
    ) {
        resolver.setAttachment(
            TerminalRemoteSessionAttachmentState(
                attachment: RemoteSessionAttachment(
                    identifier: identifier,
                    ownership: ownership
                ),
                managedSessionConfirmed: managedSessionConfirmed
            ),
            for: paneID
        )
    }

    func clearAttachmentState(for paneID: UUID) {
        resolver.clearAttachmentState(for: paneID)
        clearResumeContext(for: paneID)
    }

    func confirmManagedSession(for paneID: UUID) {
        resolver.confirmManagedSession(for: paneID)
    }

    func shouldReattachManagedSession(
        for paneID: UUID,
        backendIdentifier: RemoteSessionBackendIdentifier
    ) -> Bool {
        guard let state = resolver.attachment(for: paneID) else { return false }
        return state.attachment.identifier.backendIdentifier == backendIdentifier
            && state.attachment.ownership == .managed
            && state.managedSessionConfirmed
    }

    // MARK: - Prompt ownership

    func resolvePrompt(
        requestID: UUID,
        selection: RemoteSessionAttachSelection
    ) {
        resolver.resolvePrompt(requestID: requestID, selection: selection)
    }

    func cancelPrompt(requestID: UUID) {
        resolver.cancelPrompt(requestID: requestID)
    }

    func hasPendingPrompt(requestID: UUID) -> Bool {
        resolver.hasPendingPrompt(requestID: requestID)
    }

    func requestSelection(
        requestID: UUID,
        paneID: UUID,
        backendIdentifier: RemoteSessionBackendIdentifier,
        availableSessions: [RemoteSessionSelectionInfo]
    ) async -> RemoteSessionAttachSelection {
        await resolver.requestSelection(
            requestID: requestID,
            entityID: paneID,
            backendIdentifier: backendIdentifier,
            availableSessions: availableSessions
        )
    }

    func cancelPrompt(for startContext: SSHShellRegistry.StartContext?) {
        guard let startContext else { return }
        cancelPrompt(requestID: startContext.token.id)
    }

    func clearRuntimeState(for paneID: UUID) {
        resolver.clearRuntimeState(for: paneID)
        clearResumeContext(for: paneID)
    }

    // MARK: - Pane state

    func status(for paneID: UUID) -> RemoteSessionStatus? {
        sessionState.paneState(for: paneID)?.remoteSessionStatus
    }

    func updateStatus(_ status: RemoteSessionStatus, for paneID: UUID) {
        guard let previous = sessionState.paneState(for: paneID)?.remoteSessionStatus,
              previous != status else {
            return
        }
        sessionState.updatePane(paneID) { $0.remoteSessionStatus = status }
        logger.info(
            "Remote session status for pane \(paneID.uuidString, privacy: .public) changed from \(previous.rawValue, privacy: .public) to \(status.rawValue, privacy: .public)"
        )
    }

    func shouldApplyWorkingDirectory(for paneID: UUID) -> Bool {
        guard let status = status(for: paneID) else { return false }
        return status == .off || status == .missing
    }

    func updateSelectionStatuses(selectedTabs: [UUID: UUID]) {
        for serverID in sessionState.serverIdsWithTabs {
            for tab in sessionState.tabs(for: serverID) {
                updateFocus(
                    for: tab,
                    isSelectedTab: selectedTabs[serverID] == tab.id
                )
            }
        }
    }

    func updateFocus(for tab: TerminalTab) {
        updateFocus(
            for: tab,
            isSelectedTab: sessionState.selectedTabId(for: tab.serverId) == tab.id
        )
    }

    private func updateFocus(for tab: TerminalTab, isSelectedTab: Bool) {
        for paneID in tab.allPaneIds {
            guard let state = sessionState.paneState(for: paneID),
                  state.remoteSessionStatus == .foreground
                    || state.remoteSessionStatus == .background else {
                continue
            }
            updateStatus(
                isSelectedTab && tab.focusedPaneId == paneID ? .foreground : .background,
                for: paneID
            )
        }
    }

    func disable(for serverID: UUID) {
        for state in sessionState.paneStates(forServer: serverID) {
            updateStatus(.off, for: state.paneId)
            clearRuntimeState(for: state.paneId)
        }
    }

}

#if DEBUG
extension TerminalRemoteSessionCoordinator {
    convenience init() {
        let configuration = TerminalRemoteSessionConfiguration.testing
        let remoteSessions = UnavailableTerminalRemoteSessionService()
        let resolver = RemoteSessionAttachResolver(
            configuration: configuration,
            remoteSessions: remoteSessions
        )
        let sessionState = TerminalSessionStateStore(
            snapshotStore: EmptyTerminalTabSnapshotStore(),
            connectionViewSelections: ConnectionViewSelectionStore(),
            remoteSessionResolver: resolver
        )
        self.init(
            configuration: configuration,
            remoteSessions: remoteSessions,
            resolver: resolver,
            sessionState: sessionState,
            transportLifetime: TerminalTransportLifetime()
        )
    }
}

@MainActor
private final class EmptyTerminalTabSnapshotStore: TerminalTabSnapshotStoring {
    func loadSnapshotData() -> Data? { nil }
    func saveSnapshotData(_ data: Data) {}
    func removeSnapshotData() {}
}

extension TerminalRemoteSessionConfiguration {
    static var testing: Self {
        Self(
            deviceID: "test-device",
            enabledByDefault: { true },
            backendIdentifierByDefault: { .tmux },
            startupBehaviorByDefault: { .ask },
            serverSettings: { _ in nil },
            themeStyle: {
                RemoteSessionThemeStyle(
                    name: "Aizen Dark",
                    modeStyle: "bg=default,fg=default"
                )
            }
        )
    }
}

actor UnavailableTerminalRemoteSessionService: TerminalRemoteSessionServicing {
    nonisolated let backendMetadata = [RemoteSessionBackendMetadata(
        identifier: .tmux,
        displayName: "tmux",
        installation: .automatic,
        managedStartupCommandSupport: .supported
    )]

    func availability(
        for backendIdentifier: RemoteSessionBackendIdentifier,
        using client: SSHClient
    ) async -> RemoteSessionAvailability { .unsupportedEnvironment }

    func listSessions(
        scope: RemoteSessionListScope,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async throws -> [RemoteSessionDescriptor] { throw SSHError.notConnected }

    func prepareManagedSession(
        using client: SSHClient,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle,
        runtime: RemoteSessionRuntime
    ) async {}

    func launchPlan(
        for request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) async throws -> RemoteSessionBackendLaunchPlan { throw SSHError.notConnected }

    func installScript(
        attachment: RemoteSessionAttachment,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle,
        using client: SSHClient,
        attachAfterInstall: Bool
    ) async -> String? { nil }

    func sendScript(
        _ script: String,
        using client: SSHClient,
        shellId: UUID
    ) async throws { throw SSHError.notConnected }

    func killSession(
        _ identifier: RemoteSessionIdentifier,
        using client: SSHClient,
        runtime: RemoteSessionRuntime?
    ) async {}

    func cleanupSessions(
        keeping identifiers: Set<RemoteSessionIdentifier>,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async {}

    func currentWorkingDirectory(
        for attachment: RemoteSessionAttachment,
        using client: SSHClient,
        runtime: RemoteSessionRuntime?
    ) async -> String? { nil }
}
#endif
