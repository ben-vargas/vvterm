import Foundation

@MainActor
final class TmuxAttachResolver {
    private let configuration: TerminalTmuxConfiguration
    private let remoteTmux: any TerminalRemoteTmuxServicing

    var sessionNames: [UUID: String] = [:]
    var sessionOwnership: [UUID: TmuxSessionOwnership] = [:]
    private(set) var confirmedManagedSessions: Set<UUID> = []

    private(set) var currentPrompt: TmuxAttachPrompt?
    private var promptQueue: [TmuxAttachPrompt] = []
    private var promptContinuations: [UUID: CheckedContinuation<TmuxAttachSelection, Never>] = [:]

    init(
        configuration: TerminalTmuxConfiguration,
        remoteTmux: any TerminalRemoteTmuxServicing
    ) {
        self.configuration = configuration
        self.remoteTmux = remoteTmux
    }

    #if DEBUG
    convenience init() {
        let dependencies = TerminalTabManagerDependencies.testing(
            networkReadinessPublisher: nil,
            liveActivityRefresh: { _ in }
        )
        self.init(
            configuration: dependencies.tmuxConfiguration,
            remoteTmux: dependencies.remoteTmux
        )
    }
    #endif

    // MARK: - Settings

    var tmuxEnabledDefault: Bool {
        configuration.enabledByDefault()
    }

    var tmuxStartupBehaviorDefault: TmuxStartupBehavior {
        configuration.startupBehaviorByDefault()
    }

    func isTmuxEnabled(for serverId: UUID) -> Bool {
        if let override = configuration.serverSettings(serverId)?.enabledOverride {
            return override
        }
        return tmuxEnabledDefault
    }

    func tmuxStartupBehavior(for serverId: UUID) -> TmuxStartupBehavior {
        if let override = configuration.serverSettings(serverId)?.startupBehaviorOverride {
            return override
        }
        return tmuxStartupBehaviorDefault
    }

    // MARK: - Session Naming

    func managedSessionName(for entityId: UUID) -> String {
        "vvterm_\(configuration.deviceID)_\(entityId.uuidString)"
    }

    func sessionName(for entityId: UUID) -> String {
        sessionNames[entityId] ?? managedSessionName(for: entityId)
    }

    // MARK: - Attachment State

    func clearAttachmentState(for entityId: UUID) {
        sessionNames.removeValue(forKey: entityId)
        sessionOwnership.removeValue(forKey: entityId)
        confirmedManagedSessions.remove(entityId)
    }

    func confirmManagedSession(for entityId: UUID) {
        guard sessionOwnership[entityId] == .managed,
              sessionNames[entityId] != nil else { return }
        confirmedManagedSessions.insert(entityId)
    }

    func hasConfirmedManagedSession(for entityId: UUID) -> Bool {
        confirmedManagedSessions.contains(entityId)
    }

    func clearAllAttachmentState() {
        sessionNames.removeAll()
        sessionOwnership.removeAll()
        confirmedManagedSessions.removeAll()
    }

    func clearRuntimeState(for entityId: UUID, setPrompt: (TmuxAttachPrompt?) -> Void) {
        clearAttachmentState(for: entityId)
        let requestIds = ([currentPrompt].compactMap { $0 } + promptQueue)
            .filter { $0.paneId == entityId }
            .map(\.id)
        for requestId in requestIds {
            cancelPrompt(requestId: requestId, setPrompt: setPrompt)
        }
    }

    func updateAttachmentState(for entityId: UUID, selection: TmuxAttachSelection, setPrompt: (TmuxAttachPrompt?) -> Void) {
        switch selection {
        case .createManaged:
            let managedName = managedSessionName(for: entityId)
            if sessionNames[entityId] != managedName || sessionOwnership[entityId] != .managed {
                confirmedManagedSessions.remove(entityId)
            }
            sessionNames[entityId] = managedName
            sessionOwnership[entityId] = .managed
        case .attachExisting(let name):
            confirmedManagedSessions.remove(entityId)
            sessionNames[entityId] = name
            sessionOwnership[entityId] = ownership(for: name)
        case .skipTmux:
            clearRuntimeState(for: entityId, setPrompt: setPrompt)
        }
    }

    // MARK: - Selection Resolution

    func resolveSelection(
        for entityId: UUID,
        serverId: UUID,
        client: SSHClient,
        backend: RemoteTmuxBackend,
        requestId: UUID,
        validateOwner: () throws -> Void,
        setPrompt: @MainActor @Sendable @escaping (TmuxAttachPrompt?) -> Void
    ) async throws -> TmuxAttachSelection {
        // On reconnect, reuse the previous session choice for this tab/pane
        if let existingName = sessionNames[entityId],
           let ownership = sessionOwnership[entityId] {
            switch ownership {
            case .managed:
                return .createManaged
            case .external:
                let sessions = try await remoteTmux.listSessions(
                    using: client,
                    backend: backend
                )
                try validateOwner()
                if sessions.contains(where: { $0.name == existingName }) {
                    return .attachExisting(sessionName: existingName)
                }
                // Session no longer exists, fall through to normal resolution
            }
        }

        let behavior = tmuxStartupBehavior(for: serverId)

        switch behavior {
        case .vvtermManaged:
            return .createManaged
        case .skipTmux:
            return .skipTmux
        case .askEveryTime:
            let sessions = try await remoteTmux.listSessions(
                using: client,
                backend: backend
            )
            try validateOwner()
            return await requestSelection(
                requestId: requestId,
                entityId: entityId,
                serverId: serverId,
                availableSessions: sessionInfosForPrompt(from: sessions),
                setPrompt: setPrompt
            )
        }
    }

    // MARK: - Prompt Queue

    func resolvePrompt(requestId: UUID, selection: TmuxAttachSelection, setPrompt: (TmuxAttachPrompt?) -> Void) {
        guard let continuation = promptContinuations.removeValue(forKey: requestId) else { return }

        if currentPrompt?.id == requestId {
            currentPrompt = nil
            advancePromptQueue(setPrompt: setPrompt)
            continuation.resume(returning: selection)
            return
        }

        promptQueue.removeAll { $0.id == requestId }
        continuation.resume(returning: selection)
    }

    func cancelPrompt(requestId: UUID, setPrompt: (TmuxAttachPrompt?) -> Void) {
        resolvePrompt(requestId: requestId, selection: .skipTmux, setPrompt: setPrompt)
    }

    func hasPendingPrompt(requestId: UUID) -> Bool {
        promptContinuations[requestId] != nil
    }

    // MARK: - Filtering

    func sessionInfosForPrompt(from sessions: [RemoteTmuxSession]) -> [TmuxAttachSessionInfo] {
        let filtered = sessions.filter { !isInternalSessionName($0.name) || $0.attachedClients > 0 }
        let source = filtered.isEmpty ? sessions : filtered
        return source.map {
            TmuxAttachSessionInfo(
                name: $0.name,
                attachedClients: max(0, $0.attachedClients),
                windowCount: max(1, $0.windowCount)
            )
        }
    }

    func isInternalSessionName(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased.hasPrefix("vvterm_")
            || lowercased.hasPrefix("vvterm-")
            || lowercased.hasPrefix("vivyterm_")
            || lowercased.hasPrefix("vivyterm-")
    }

    func isCurrentDeviceManagedSessionName(_ name: String) -> Bool {
        name.hasPrefix("vvterm_\(configuration.deviceID)_")
    }

    // MARK: - Prompt Requests

    func requestSelection(
        requestId: UUID,
        entityId: UUID,
        serverId: UUID,
        availableSessions: [TmuxAttachSessionInfo],
        setPrompt: @MainActor @Sendable @escaping (TmuxAttachPrompt?) -> Void
    ) async -> TmuxAttachSelection {
        let serverName = configuration.serverSettings(serverId)?.name
            ?? String(localized: "Server")
        let prompt = TmuxAttachPrompt(
            id: requestId,
            paneId: entityId,
            serverId: serverId,
            serverName: serverName,
            existingSessions: availableSessions
        )

        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .skipTmux }
            return await withCheckedContinuation { continuation in
                enqueuePrompt(prompt, continuation: continuation, setPrompt: setPrompt)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPrompt(
                    requestId: requestId,
                    setPrompt: setPrompt
                )
            }
        }
    }

    private func enqueuePrompt(
        _ prompt: TmuxAttachPrompt,
        continuation: CheckedContinuation<TmuxAttachSelection, Never>,
        setPrompt: (TmuxAttachPrompt?) -> Void
    ) {
        promptContinuations[prompt.id] = continuation
        if currentPrompt == nil {
            currentPrompt = prompt
            setPrompt(prompt)
        } else {
            promptQueue.append(prompt)
        }
    }

    private func advancePromptQueue(setPrompt: (TmuxAttachPrompt?) -> Void) {
        guard currentPrompt == nil, !promptQueue.isEmpty else {
            setPrompt(currentPrompt)
            return
        }
        currentPrompt = promptQueue.removeFirst()
        setPrompt(currentPrompt)
    }

    private func ownership(for sessionName: String) -> TmuxSessionOwnership {
        isCurrentDeviceManagedSessionName(sessionName) ? .managed : .external
    }
}
