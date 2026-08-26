import Foundation

@MainActor
extension TerminalRemoteSessionCoordinator {
    private enum InstallOutcome: Sendable {
        case installed(TerminalRemoteSessionAttachmentState)
        case unavailable
        case missing
        case indeterminate
    }

    func startInstall(
        for paneID: UUID,
        onInstalled: @MainActor @escaping () -> Void
    ) async {
        if let runtime = transportLifetime.registry.runtime(for: paneID) {
            await startEternalTerminalInstall(
                for: paneID,
                runtime: runtime,
                onInstalled: onInstalled
            )
            return
        }
        guard let registration = shellRegistration(for: paneID),
              isEnabled(for: registration.serverID) else {
            return
        }
        updateStatus(.installing, for: paneID)
        do {
            let outcome = try await performInstall(
                for: paneID,
                serverID: registration.serverID,
                using: registration.client,
                sendScript: { script in
                    try await self.remoteSessions.sendScript(
                        script,
                        using: registration.client,
                        shellId: registration.shellID
                    )
                },
                validateOwner: { self.ownsShell(registration, for: paneID) }
            )
            guard ownsShell(registration, for: paneID) else { return }
            await finishInstall(
                outcome,
                for: paneID,
                onInstalled: onInstalled,
                beforeReconnect: {
                    await self.transportLifetime.unregisterShell(
                        for: paneID,
                        ifOwnedBy: registration
                    )
                }
            )
        } catch is CancellationError {
            return
        } catch {
            guard ownsShell(registration, for: paneID) else { return }
            updateStatus(.unknown, for: paneID)
        }
    }

    private func startEternalTerminalInstall(
        for paneID: UUID,
        runtime: EternalTerminalRuntime,
        onInstalled: @MainActor @escaping () -> Void
    ) async {
        guard let serverID = sessionState.paneState(for: paneID)?.serverId,
              isEnabled(for: serverID),
              transportLifetime.registry.isCurrentRuntime(runtime, for: paneID) else {
            return
        }
        updateStatus(.installing, for: paneID)
        do {
            let outcome = try await runtime.withBootstrapSSHClient { client in
                try await self.performInstall(
                    for: paneID,
                    serverID: serverID,
                    using: client,
                    sendScript: { script in
                        try await runtime.sendInteractiveScript(script)
                    },
                    validateOwner: {
                        self.transportLifetime.registry.isCurrentRuntime(runtime, for: paneID)
                    }
                )
            }
            guard transportLifetime.registry.isCurrentRuntime(runtime, for: paneID) else {
                return
            }
            await finishInstall(
                outcome,
                for: paneID,
                onInstalled: onInstalled,
                beforeReconnect: {
                    if await self.transportLifetime.unregisterRuntime(
                        for: paneID,
                        ifOwnedBy: runtime
                    ) {
                        self.sessionState.updatePane(paneID) { $0.transportState = .ssh }
                    }
                }
            )
        } catch is CancellationError {
            return
        } catch {
            guard transportLifetime.registry.isCurrentRuntime(runtime, for: paneID) else {
                return
            }
            updateStatus(.unknown, for: paneID)
        }
    }

    private func performInstall(
        for paneID: UUID,
        serverID: UUID,
        using client: SSHClient,
        sendScript: @MainActor @Sendable (String) async throws -> Void,
        validateOwner: @MainActor @Sendable () -> Bool
    ) async throws -> InstallOutcome {
        let backendIdentifier = backendIdentifier(for: serverID)
        let identifier = try resolver.managedIdentifier(
            for: paneID,
            serverID: serverID,
            backendIdentifier: backendIdentifier
        )
        let attachment = RemoteSessionAttachment(
            identifier: identifier,
            ownership: .managed
        )
        let workingDirectory = await resolveWorkingDirectory(
            for: paneID,
            using: client,
            runtime: nil
        )
        try Task.checkCancellation()
        guard validateOwner() else { throw CancellationError() }
        let terminalType = await client.remoteTerminalType()
        guard let script = await remoteSessions.installScript(
            attachment: attachment,
            workingDirectory: workingDirectory,
            terminalType: terminalType,
            themeStyle: configuration.themeStyle(),
            using: client,
            attachAfterInstall: false
        ) else {
            return .unavailable
        }
        try await sendScript(script)

        var observedIndeterminate = false
        for _ in 0..<6 {
            try await Task.sleep(for: .seconds(2))
            guard validateOwner() else { throw CancellationError() }
            switch await remoteSessions.availability(
                for: backendIdentifier,
                using: client
            ) {
            case .available:
                return .installed(TerminalRemoteSessionAttachmentState(
                    attachment: attachment,
                    managedSessionConfirmed: false
                ))
            case .confirmedMissing, .incompatible:
                continue
            case .indeterminate:
                observedIndeterminate = true
            case .unsupportedEnvironment:
                return .unavailable
            }
        }
        return observedIndeterminate ? .indeterminate : .missing
    }

    private func finishInstall(
        _ outcome: InstallOutcome,
        for paneID: UUID,
        onInstalled: @MainActor @escaping () -> Void,
        beforeReconnect: @MainActor @Sendable () async -> Void
    ) async {
        switch outcome {
        case .installed(let attachment):
            await beforeReconnect()
            completeInstall(
                for: paneID,
                attachment: attachment,
                onInstalled: onInstalled
            )
        case .unavailable:
            updateStatus(.off, for: paneID)
        case .missing:
            updateStatus(.missing, for: paneID)
        case .indeterminate:
            updateStatus(.unknown, for: paneID)
        }
    }

    func completeInstall(
        for paneID: UUID,
        attachment: TerminalRemoteSessionAttachmentState,
        onInstalled: () -> Void
    ) {
        guard sessionState.containsPane(paneID) else { return }
        resolver.setAttachment(attachment, for: paneID)
        sessionState.requestPersistence()
        onInstalled()
    }

    func managedSessionIdentifierToKill(
        for paneID: UUID,
        status: RemoteSessionStatus
    ) -> RemoteSessionIdentifier? {
        guard status == .foreground || status == .background || status == .installing,
              let state = resolver.attachment(for: paneID),
              state.attachment.ownership == .managed else {
            return nil
        }
        return state.attachment.identifier
    }

    func killIfNeeded(for paneID: UUID) {
        guard let registration = shellRegistration(for: paneID),
              let state = resolver.attachment(for: paneID),
              state.attachment.ownership == .managed else {
            return
        }
        let identifier = state.attachment.identifier
        Task.detached { [remoteSessions, identifier, client = registration.client] in
            await remoteSessions.killSession(identifier, using: client, runtime: nil)
        }
    }

    func killSession(
        _ identifier: RemoteSessionIdentifier,
        using client: SSHClient
    ) async {
        await remoteSessions.killSession(identifier, using: client, runtime: nil)
    }

    func killSession(
        _ identifier: RemoteSessionIdentifier,
        using runtime: EternalTerminalRuntime
    ) async {
        await runtime.killManagedRemoteSession(identifier)
    }

    func resetRuntimeState(for paneIDs: Set<UUID>) {
        for paneID in paneIDs {
            clearRuntimeState(for: paneID)
        }
        resolver.cancelAllPrompts()
        completedCleanup.removeAll()
    }

    private func shellRegistration(
        for paneID: UUID
    ) -> TerminalRemoteSessionShellRegistration? {
        transportLifetime.registry.shellRegistration(for: paneID).map {
            TerminalRemoteSessionShellRegistration(
                client: $0.client,
                shellID: $0.shellId,
                serverID: $0.serverId
            )
        }
    }

    private func ownsShell(
        _ registration: TerminalRemoteSessionShellRegistration,
        for paneID: UUID
    ) -> Bool {
        transportLifetime.registry.ownsShell(
            client: registration.client,
            shellId: registration.shellID,
            for: paneID
        )
    }
}
