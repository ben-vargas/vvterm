import Foundation

nonisolated struct RemoteSessionLifecycleContext: Codable, Hashable, Sendable {
    let attachment: RemoteSessionAttachment
    let observation: RemoteSessionLifecycleObservation

    private enum CodingKeys: String, CodingKey {
        case attachment
        case envelope
        case presenceProbe
        case legacyTmuxMarkerToken
    }

    init(
        attachment: RemoteSessionAttachment,
        envelope: RemoteSessionLifecycleEnvelope,
        presenceProbe: RemoteSessionPresenceProbe
    ) {
        self.attachment = attachment
        observation = .current(envelope: envelope, presenceProbe: presenceProbe)
    }

    init(
        attachment: RemoteSessionAttachment,
        legacyTmuxMarkerToken: String
    ) throws {
        self.attachment = attachment
        observation = try RemoteSessionLifecycleObservation(
            legacyTmuxMarkerToken: legacyTmuxMarkerToken
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attachment = try container.decode(RemoteSessionAttachment.self, forKey: .attachment)
        if let envelope = try container.decodeIfPresent(
            RemoteSessionLifecycleEnvelope.self,
            forKey: .envelope
        ) {
            observation = .current(
                envelope: envelope,
                presenceProbe: try container.decode(
                    RemoteSessionPresenceProbe.self,
                    forKey: .presenceProbe
                )
            )
        } else {
            observation = try RemoteSessionLifecycleObservation(
                legacyTmuxMarkerToken: container.decode(
                    String.self,
                    forKey: .legacyTmuxMarkerToken
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attachment, forKey: .attachment)
        switch observation {
        case .current(let envelope, let presenceProbe):
            try container.encode(envelope, forKey: .envelope)
            try container.encode(presenceProbe, forKey: .presenceProbe)
        case .legacyTmux(let markerToken):
            try container.encode(markerToken, forKey: .legacyTmuxMarkerToken)
        }
    }
}

nonisolated struct TerminalShellStartupPlan: Sendable {
    let command: String?
    let remoteSessionLifecycle: RemoteSessionLifecycleContext?
    let mayExecuteUserStartupAction: Bool

    var mayExecuteStandaloneUserStartupAction: Bool {
        remoteSessionLifecycle == nil && mayExecuteUserStartupAction
    }

    nonisolated static let plainShell = TerminalShellStartupPlan(
        command: nil,
        remoteSessionLifecycle: nil,
        mayExecuteUserStartupAction: false
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
