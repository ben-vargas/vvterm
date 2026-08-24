import Foundation

nonisolated struct RemoteSessionLifecycleContext: Codable, Hashable, Sendable {
    let attachment: RemoteSessionAttachment
    let envelope: RemoteSessionLifecycleEnvelope
    let presenceProbe: RemoteSessionPresenceProbe
}

nonisolated struct TerminalShellStartupPlan: Sendable {
    let command: String?
    let remoteSessionLifecycle: RemoteSessionLifecycleContext?

    nonisolated static let plainShell = TerminalShellStartupPlan(
        command: nil,
        remoteSessionLifecycle: nil
    )
}

nonisolated enum TerminalShellEndReason: Hashable, Sendable {
    case transportInterrupted
    case remoteSessionDetached(RemoteSessionOwnership)
    case remoteSessionTerminated(RemoteSessionOwnership)
    case remoteSessionCreationFailed
    case remoteSessionAttachFailed
    case observationAmbiguous

    nonisolated static func resolve(
        lifecycle: RemoteSessionLifecycleContext?,
        event: RemoteSessionEvent?,
        sessionExists: Bool?
    ) -> Self {
        guard let lifecycle else {
            return .transportInterrupted
        }

        switch event {
        case .detached:
            return .remoteSessionDetached(lifecycle.attachment.ownership)
        case .terminated:
            return .remoteSessionTerminated(lifecycle.attachment.ownership)
        case .creationFailed:
            return .remoteSessionCreationFailed
        case .attachFailed:
            return .remoteSessionAttachFailed
        case .transportInterrupted:
            return .transportInterrupted
        case .observationAmbiguous:
            return .observationAmbiguous
        case .attached, nil:
            switch sessionExists {
            case true:
                return .remoteSessionDetached(lifecycle.attachment.ownership)
            case false:
                return .remoteSessionTerminated(lifecycle.attachment.ownership)
            case nil:
                return .observationAmbiguous
            }
        }
    }
}

nonisolated enum TerminalDisconnectReason: String, Codable, Hashable, Sendable {
    // Keep raw values stable for local snapshot migration.
    case transportInterrupted = "transportEnded"
    case remoteSessionDetached = "tmuxDetached"
    case externalRemoteSessionTerminated = "externalTmuxEnded"

    var allowsAutomaticReconnect: Bool {
        self == .transportInterrupted
    }
}

nonisolated enum TerminalTeardownIntent: CaseIterable, Sendable {
    case explicitClose
    case explicitServerDisconnect
    case remoteSessionEnded
    case applicationTermination

    var removesPersistedDescriptor: Bool {
        self != .applicationTermination
    }

    var terminatesManagedRemoteSession: Bool {
        switch self {
        case .explicitClose, .explicitServerDisconnect:
            true
        case .remoteSessionEnded, .applicationTermination:
            false
        }
    }

    var deletesResumableSessionState: Bool {
        self != .applicationTermination
    }
}
