import Combine
import Foundation

@MainActor
final class RemoteSessionAttachResolver: ObservableObject {
    private let configuration: TerminalRemoteSessionConfiguration
    private let remoteSessions: any TerminalRemoteSessionServicing
    private(set) var attachments: [UUID: TerminalRemoteSessionAttachmentState] = [:]

    @Published private(set) var currentPrompt: RemoteSessionAttachPrompt?
    private var promptQueue: [RemoteSessionAttachPrompt] = []
    private var promptContinuations: [
        UUID: CheckedContinuation<RemoteSessionAttachSelection, Never>
    ] = [:]

    init(
        configuration: TerminalRemoteSessionConfiguration,
        remoteSessions: any TerminalRemoteSessionServicing
    ) {
        self.configuration = configuration
        self.remoteSessions = remoteSessions
    }

    var enabledByDefault: Bool {
        configuration.enabledByDefault()
    }

    var backendIdentifierByDefault: RemoteSessionBackendIdentifier {
        configuration.backendIdentifierByDefault()
    }

    var startupBehaviorByDefault: RemoteSessionStartupBehavior {
        configuration.startupBehaviorByDefault()
    }

    func isEnabled(for serverID: UUID) -> Bool {
        guard isKnownBackend(backendIdentifier(for: serverID)) else {
            return false
        }
        return configuration.serverSettings(serverID)?.enabledOverride ?? enabledByDefault
    }

    func backendIdentifier(for serverID: UUID) -> RemoteSessionBackendIdentifier {
        configuration.serverSettings(serverID)?.backendIdentifier
            ?? backendIdentifierByDefault
    }

    func startupBehavior(for serverID: UUID) -> RemoteSessionStartupBehavior {
        configuration.serverSettings(serverID)?.startupBehaviorOverride
            ?? startupBehaviorByDefault
    }

    func isKnownBackend(_ identifier: RemoteSessionBackendIdentifier) -> Bool {
        remoteSessions.backendMetadata.contains { $0.identifier == identifier }
    }

    func managedIdentifier(
        for entityID: UUID,
        serverID: UUID,
        backendIdentifier: RemoteSessionBackendIdentifier
    ) throws -> RemoteSessionIdentifier {
        try remoteSessions.managedIdentifier(
            deviceID: configuration.deviceID,
            entityID: entityID,
            serverName: configuration.serverSettings(serverID)?.name ?? "server",
            backendIdentifier: backendIdentifier
        )
    }

    func attachment(for entityID: UUID) -> TerminalRemoteSessionAttachmentState? {
        attachments[entityID]
    }

    func restoreAttachments(_ restored: [UUID: TerminalRemoteSessionAttachmentState]) {
        attachments = restored
    }

    func setAttachment(
        _ state: TerminalRemoteSessionAttachmentState,
        for entityID: UUID
    ) {
        attachments[entityID] = state
    }

    func clearAttachmentState(for entityID: UUID) {
        attachments.removeValue(forKey: entityID)
    }

    func confirmManagedSession(for entityID: UUID) {
        guard var state = attachments[entityID],
              state.attachment.ownership == .managed else {
            return
        }
        state.managedSessionConfirmed = true
        attachments[entityID] = state
    }

    func clearAllAttachmentState() {
        attachments.removeAll()
    }

    func clearRuntimeState(for entityID: UUID) {
        clearAttachmentState(for: entityID)
        let requestIDs = ([currentPrompt].compactMap { $0 } + promptQueue)
            .filter { $0.paneId == entityID }
            .map(\.id)
        for requestID in requestIDs {
            cancelPrompt(requestID: requestID)
        }
    }

    func updateAttachmentState(
        for entityID: UUID,
        serverID: UUID,
        backendIdentifier: RemoteSessionBackendIdentifier,
        selection: RemoteSessionAttachSelection
    ) throws {
        switch selection {
        case .createManaged:
            if let state = attachments[entityID],
               state.attachment.ownership == .managed,
               state.attachment.identifier.backendIdentifier == backendIdentifier {
                // A restored identifier is authoritative. It can use an older
                // naming format or contain a server name from before a rename.
                return
            }
            let attachment = RemoteSessionAttachment(
                identifier: try managedIdentifier(
                    for: entityID,
                    serverID: serverID,
                    backendIdentifier: backendIdentifier
                ),
                ownership: .managed
            )
            attachments[entityID] = TerminalRemoteSessionAttachmentState(
                attachment: attachment,
                managedSessionConfirmed: false
            )
        case .attachExisting(let attachment):
            guard attachment.identifier.backendIdentifier == backendIdentifier else {
                throw SSHError.unknown("Remote session backend mismatch")
            }
            attachments[entityID] = TerminalRemoteSessionAttachmentState(
                attachment: attachment,
                managedSessionConfirmed: false
            )
        case .plainShell:
            clearRuntimeState(for: entityID)
        }
    }

    func resolveSelection(
        for entityID: UUID,
        serverID: UUID,
        client: SSHClient,
        runtime: RemoteSessionRuntime,
        requestID: UUID,
        validateOwner: () throws -> Void
    ) async throws -> RemoteSessionAttachSelection {
        if let state = attachments[entityID],
           state.attachment.identifier.backendIdentifier == runtime.backendIdentifier {
            switch state.attachment.ownership {
            case .managed:
                return .createManaged
            case .external:
                let sessions = try await remoteSessions.listSessions(
                    scope: .userVisible,
                    using: client,
                    runtime: runtime
                )
                try validateOwner()
                if sessions.contains(where: { $0.id == state.attachment.identifier }) {
                    return .attachExisting(state.attachment)
                }
            }
        }

        switch startupBehavior(for: serverID) {
        case .createManaged:
            return .createManaged
        case .plainShell:
            return .plainShell
        case .ask:
            let sessions = try await remoteSessions.listSessions(
                scope: .userVisible,
                using: client,
                runtime: runtime
            )
            try validateOwner()
            return await requestSelection(
                requestID: requestID,
                entityID: entityID,
                backendIdentifier: runtime.backendIdentifier,
                availableSessions: selectionInfo(from: sessions)
            )
        }
    }

    func resolvePrompt(
        requestID: UUID,
        selection: RemoteSessionAttachSelection
    ) {
        guard let continuation = promptContinuations.removeValue(forKey: requestID) else {
            return
        }
        if currentPrompt?.id == requestID {
            currentPrompt = nil
            advancePromptQueue()
        } else {
            promptQueue.removeAll { $0.id == requestID }
        }
        continuation.resume(returning: selection)
    }

    func cancelPrompt(requestID: UUID) {
        resolvePrompt(requestID: requestID, selection: .plainShell)
    }

    func hasPendingPrompt(requestID: UUID) -> Bool {
        promptContinuations[requestID] != nil
    }

    func cancelAllPrompts() {
        let requestIDs = ([currentPrompt].compactMap { $0 } + promptQueue).map(\.id)
        for requestID in requestIDs {
            cancelPrompt(requestID: requestID)
        }
    }

    func selectionInfo(
        from sessions: [RemoteSessionDescriptor]
    ) -> [RemoteSessionSelectionInfo] {
        let filtered = sessions.filter {
            $0.attachment.ownership == .external
                || ($0.attachedClientCount ?? 0) > 0
        }
        let source = filtered.isEmpty ? sessions : filtered
        return source.map {
            RemoteSessionSelectionInfo(
                attachment: $0.attachment,
                attachedClientCount: $0.attachedClientCount,
                containerCount: $0.containerCount
            )
        }
    }

    func requestSelection(
        requestID: UUID,
        entityID: UUID,
        backendIdentifier: RemoteSessionBackendIdentifier,
        availableSessions: [RemoteSessionSelectionInfo]
    ) async -> RemoteSessionAttachSelection {
        let backendName = remoteSessions.backendMetadata.first {
            $0.identifier == backendIdentifier
        }?.displayName ?? backendIdentifier.rawValue
        let prompt = RemoteSessionAttachPrompt(
            id: requestID,
            paneId: entityID,
            backendName: backendName,
            existingSessions: availableSessions
        )
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .plainShell }
            return await withCheckedContinuation { continuation in
                enqueuePrompt(prompt, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPrompt(requestID: requestID)
            }
        }
    }

    private func enqueuePrompt(
        _ prompt: RemoteSessionAttachPrompt,
        continuation: CheckedContinuation<RemoteSessionAttachSelection, Never>
    ) {
        promptContinuations[prompt.id] = continuation
        if currentPrompt == nil {
            currentPrompt = prompt
        } else {
            promptQueue.append(prompt)
        }
    }

    private func advancePromptQueue() {
        guard currentPrompt == nil, !promptQueue.isEmpty else { return }
        currentPrompt = promptQueue.removeFirst()
    }

}
