import Foundation
import os.log

actor RemoteSessionClient {
    nonisolated let registry: RemoteSessionBackendRegistry
    private let logger = Logger(subsystem: "app.vivy.VivyTerm", category: "RemoteSessionClient")

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

    func launchPlan(
        for request: RemoteSessionLaunchRequest,
        runtime: RemoteSessionRuntime
    ) async throws -> RemoteSessionBackendLaunchPlan {
        guard request.attachment.identifier.backendIdentifier == runtime.backendIdentifier,
              let backend = registry.backend(for: runtime.backendIdentifier) else {
            throw SSHError.unknown("Remote session backend mismatch")
        }
        if case .ensureManaged(_, let initialCommand) = request.intent,
           initialCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           backend.metadata.managedStartupCommandSupport == .unsupported {
            throw SSHError.managedStartupCommandUnsupported(
                backend.metadata.displayName
            )
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
        do {
            try await backend.killSession(identifier, using: client, runtime: runtime)
        } catch {
            logger.warning("Remote session removal failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func cleanupSessions(
        keeping identifiers: @escaping @Sendable () async throws -> Set<RemoteSessionIdentifier>,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async throws {
        guard let backend = registry.backend(for: runtime.backendIdentifier) else {
            throw SSHError.unknown("Unknown remote session backend")
        }
        try Task.checkCancellation()
        let sessions = try await backend.listSessions(
            scope: .managedCleanup,
            using: client,
            runtime: runtime
        )
        for session in sessions {
            try Task.checkCancellation()
            let protectedIdentifiers = try await identifiers()
            try Task.checkCancellation()
            let candidates = RemoteSessionCleanupPolicy.identifiersToDelete(
                from: [session], keeping: protectedIdentifiers
            )
            for identifier in candidates {
                try await backend.killSession(identifier, using: client, runtime: runtime)
            }
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
