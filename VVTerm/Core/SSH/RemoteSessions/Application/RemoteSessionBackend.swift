import Foundation

nonisolated protocol RemoteSessionBackend: Sendable {
    var metadata: RemoteSessionBackendMetadata { get }

    func managedIdentifier(
        deviceID: String,
        entityID: UUID,
        serverName: String
    ) throws -> RemoteSessionIdentifier
    func availability(using client: SSHClient) async -> RemoteSessionAvailability
    func listSessions(
        scope: RemoteSessionListScope,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async throws -> [RemoteSessionDescriptor]
    func prepareManagedSession(
        using client: SSHClient,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle,
        runtime: RemoteSessionRuntime
    ) async
    func launchPlan(
        for request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) throws -> RemoteSessionBackendLaunchPlan
    func installScript(
        attachment: RemoteSessionAttachment,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle,
        using client: SSHClient,
        attachAfterInstall: Bool
    ) async -> String?
    func killSession(
        _ identifier: RemoteSessionIdentifier,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async
    func currentWorkingDirectory(
        for attachment: RemoteSessionAttachment,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async -> String?
}

extension RemoteSessionBackend {
    nonisolated func managedIdentifier(
        deviceID: String,
        entityID: UUID,
        serverName: String
    ) throws -> RemoteSessionIdentifier {
        try RemoteSessionManagedIdentifierPolicy.identifier(
            backendIdentifier: metadata.identifier,
            serverName: serverName,
            deviceID: deviceID,
            entityID: entityID
        )
    }
}

nonisolated struct RemoteSessionBackendRegistry: Sendable {
    private let backends: [RemoteSessionBackendIdentifier: any RemoteSessionBackend]

    init(backends: [any RemoteSessionBackend]) {
        var indexed: [RemoteSessionBackendIdentifier: any RemoteSessionBackend] = [:]
        for backend in backends {
            precondition(indexed[backend.metadata.identifier] == nil)
            indexed[backend.metadata.identifier] = backend
        }
        self.backends = indexed
    }

    var metadata: [RemoteSessionBackendMetadata] {
        backends.values.map(\.metadata).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func backend(
        for identifier: RemoteSessionBackendIdentifier
    ) -> (any RemoteSessionBackend)? {
        backends[identifier]
    }
}

actor RemoteSessionClient {
    nonisolated let registry: RemoteSessionBackendRegistry

    init(registry: RemoteSessionBackendRegistry) {
        self.registry = registry
    }

    nonisolated var backendMetadata: [RemoteSessionBackendMetadata] {
        registry.metadata
    }

    nonisolated func managedIdentifier(
        deviceID: String,
        entityID: UUID,
        serverName: String,
        backendIdentifier: RemoteSessionBackendIdentifier
    ) throws -> RemoteSessionIdentifier {
        guard let backend = registry.backend(for: backendIdentifier) else {
            throw SSHError.unknown("Unknown remote session backend")
        }
        return try backend.managedIdentifier(
            deviceID: deviceID,
            entityID: entityID,
            serverName: serverName
        )
    }

    func availability(
        for backendIdentifier: RemoteSessionBackendIdentifier,
        using client: SSHClient
    ) async -> RemoteSessionAvailability {
        guard let backend = registry.backend(for: backendIdentifier) else {
            return .unsupportedEnvironment
        }
        return await backend.availability(using: client)
    }

    func listSessions(
        scope: RemoteSessionListScope,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async throws -> [RemoteSessionDescriptor] {
        guard let backend = registry.backend(for: runtime.backendIdentifier) else {
            throw SSHError.unknown("Unknown remote session backend")
        }
        return try await backend.listSessions(
            scope: scope,
            using: client,
            runtime: runtime
        )
    }

    func prepareManagedSession(
        using client: SSHClient,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle,
        runtime: RemoteSessionRuntime
    ) async {
        guard let backend = registry.backend(for: runtime.backendIdentifier) else { return }
        await backend.prepareManagedSession(
            using: client,
            terminalType: terminalType,
            themeStyle: themeStyle,
            runtime: runtime
        )
    }

    func launchPlan(
        for request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) async throws -> RemoteSessionBackendLaunchPlan {
        guard request.attachment.identifier.backendIdentifier == runtime.backendIdentifier,
              let backend = registry.backend(for: runtime.backendIdentifier) else {
            throw SSHError.unknown("Remote session backend mismatch")
        }
        return try backend.launchPlan(for: request, runtime: runtime)
    }

    func installScript(
        attachment: RemoteSessionAttachment,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        themeStyle: RemoteSessionThemeStyle,
        using client: SSHClient,
        attachAfterInstall: Bool
    ) async -> String? {
        guard let backend = registry.backend(for: attachment.identifier.backendIdentifier) else {
            return nil
        }
        return await backend.installScript(
            attachment: attachment,
            workingDirectory: workingDirectory,
            terminalType: terminalType,
            themeStyle: themeStyle,
            using: client,
            attachAfterInstall: attachAfterInstall
        )
    }

    func sendScript(_ script: String, using client: SSHClient, shellId: UUID) async throws {
        let payload = script.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        try await client.write(data, to: shellId)
    }

    func killSession(
        _ identifier: RemoteSessionIdentifier,
        using client: SSHClient,
        runtime explicitRuntime: RemoteSessionRuntime? = nil
    ) async {
        guard let backend = registry.backend(for: identifier.backendIdentifier) else { return }
        let runtime: RemoteSessionRuntime
        if let explicitRuntime {
            runtime = explicitRuntime
        } else {
            guard case .available(let probe) = await backend.availability(using: client) else {
                return
            }
            runtime = RemoteSessionRuntime(probe: probe)
        }
        await backend.killSession(identifier, using: client, runtime: runtime)
    }

    func cleanupSessions(
        keeping identifiers: Set<RemoteSessionIdentifier>,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async {
        guard let backend = registry.backend(for: runtime.backendIdentifier) else { return }
        guard let sessions = try? await backend.listSessions(
            scope: .managedCleanup,
            using: client,
            runtime: runtime
        ) else {
            return
        }
        let identifiersToDelete = RemoteSessionCleanupPolicy.identifiersToDelete(
            from: sessions,
            keeping: identifiers
        )
        for identifier in identifiersToDelete {
            await backend.killSession(identifier, using: client, runtime: runtime)
        }
    }

    func currentWorkingDirectory(
        for attachment: RemoteSessionAttachment,
        using client: SSHClient,
        runtime explicitRuntime: RemoteSessionRuntime? = nil
    ) async -> String? {
        let identifier = attachment.identifier
        guard let backend = registry.backend(for: identifier.backendIdentifier) else { return nil }
        let runtime: RemoteSessionRuntime
        if let explicitRuntime {
            runtime = explicitRuntime
        } else {
            guard case .available(let probe) = await backend.availability(using: client) else {
                return nil
            }
            runtime = RemoteSessionRuntime(probe: probe)
        }
        return await backend.currentWorkingDirectory(
            for: attachment,
            using: client,
            runtime: runtime
        )
    }
}
