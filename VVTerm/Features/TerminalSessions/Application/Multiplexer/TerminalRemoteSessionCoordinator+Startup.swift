import Foundation
import os.log

@MainActor
extension TerminalRemoteSessionCoordinator {
    func startupPlan(
        for paneID: UUID,
        serverID: UUID,
        client: SSHClient,
        startToken: SSHShellRegistry.StartToken,
        availabilityResolver: (() async -> RemoteSessionAvailability)? = nil,
        transport: ShellTransport = .ssh
    ) async throws -> TerminalShellStartupPlan {
        let backendIdentifier = backendIdentifier(for: serverID)
        return try await startupPlan(
            for: paneID,
            serverID: serverID,
            client: client,
            backendIdentifier: backendIdentifier,
            availabilityResolver: availabilityResolver ?? {
                await self.remoteSessions.availability(
                    for: backendIdentifier,
                    using: client
                )
            },
            transport: transport,
            requestID: startToken.id,
            validateOwner: {
                try self.requireCurrentShellOwner(
                    for: paneID,
                    client: client,
                    startToken: startToken
                )
            }
        )
    }

    func eternalTerminalStartupPlan(
        for paneID: UUID,
        serverID: UUID,
        client: SSHClient,
        runtimeToken: UUID
    ) async throws -> TerminalShellStartupPlan {
        let backendIdentifier = backendIdentifier(for: serverID)
        let plan = try await startupPlan(
            for: paneID,
            serverID: serverID,
            client: client,
            backendIdentifier: backendIdentifier,
            availabilityResolver: {
                await self.remoteSessions.availability(
                    for: backendIdentifier,
                    using: client
                )
            },
            transport: .eternalTerminal,
            requestID: runtimeToken,
            validateOwner: {
                try Task.checkCancellation()
                guard self.transportLifetime.registry.runtime(for: paneID)?.identityToken
                        == runtimeToken else {
                    throw CancellationError()
                }
            }
        )

        let remotePath = EternalTerminalStartupCommand.remoteScriptPath(token: runtimeToken)
        if let script = EternalTerminalStartupCommand.script(
            for: plan,
            remotePath: remotePath
        ) {
            try Task.checkCancellation()
            guard transportLifetime.registry.runtime(for: paneID)?.identityToken
                    == runtimeToken else {
                throw CancellationError()
            }
            try await client.upload(Data(script.utf8), to: remotePath, permissions: 0o700)
            return TerminalShellStartupPlan(
                command: EternalTerminalStartupCommand.invocation(remotePath: remotePath),
                remoteSessionLifecycle: plan.remoteSessionLifecycle,
                mayExecuteUserStartupAction: plan.mayExecuteUserStartupAction
            )
        }

        guard plan.command == nil,
              let workingDirectory = sessionState.paneState(for: paneID)?.workingDirectory,
              !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return plan
        }
        let environment = await client.remoteEnvironment()
        let restorePlan = RemoteTerminalBootstrap.workingDirectoryRestorePlan(
            for: workingDirectory,
            environment: environment
        )
        guard case .command(let command) = restorePlan else {
            return plan
        }
        return TerminalShellStartupPlan(
            command: command,
            remoteSessionLifecycle: nil,
            mayExecuteUserStartupAction: false
        )
    }

    private func startupPlan(
        for paneID: UUID,
        serverID: UUID,
        client: SSHClient,
        backendIdentifier: RemoteSessionBackendIdentifier,
        availabilityResolver: () async -> RemoteSessionAvailability,
        transport: ShellTransport,
        requestID: UUID,
        validateOwner: () throws -> Void
    ) async throws -> TerminalShellStartupPlan {
        try validateOwner()
        let startupAction = configuration.serverSettings(serverID)?.startupAction
        guard isEnabled(for: serverID) else {
            disableAttachment(for: paneID, status: .off)
            return plainShellStartupPlan(startupAction)
        }

        let availability = await availabilityResolver()
        try validateOwner()
        let runtime: RemoteSessionRuntime
        switch availability {
        case .unsupportedEnvironment:
            disableAttachment(for: paneID, status: .off)
            return .plainShell
        case .confirmedMissing, .incompatible:
            disableAttachment(for: paneID, status: .missing)
            return .plainShell
        case .indeterminate(let failure):
            logger.warning(
                "Preserving remote-session attachment for pane \(paneID.uuidString, privacy: .public) after indeterminate probe: \(failure.logDescription, privacy: .public)"
            )
            throw failure.retryError
        case .available(let probe):
            guard probe.backendIdentifier == backendIdentifier else {
                throw SSHError.unknown("Remote session backend mismatch")
            }
            runtime = RemoteSessionRuntime(probe: probe)
        }

        let isReattachingManagedSession = shouldReattachManagedSession(
            for: paneID,
            backendIdentifier: backendIdentifier
        )
        let selection = try await resolver.resolveSelection(
            for: paneID,
            serverID: serverID,
            client: client,
            runtime: runtime,
            requestID: requestID,
            validateOwner: validateOwner
        )
        try validateOwner()
        try resolver.updateAttachmentState(
            for: paneID,
            serverID: serverID,
            backendIdentifier: backendIdentifier,
            selection: selection
        )
        sessionState.requestPersistence()

        guard selection != .plainShell else {
            updateStatus(.off, for: paneID)
            clearResumeContext(for: paneID)
            return .plainShell
        }

        await runCleanupIfNeeded(
            for: serverID,
            paneID: paneID,
            using: client,
            runtime: runtime
        )
        try validateOwner()
        await prepareActivePane(
            for: paneID,
            serverID: serverID,
            using: client,
            runtime: runtime
        )
        try validateOwner()

        let workingDirectory = await resolveWorkingDirectory(
            for: paneID,
            using: client,
            runtime: runtime
        )
        try validateOwner()
        if workingDirectory != "~" {
            sessionState.updatePane(paneID) { $0.workingDirectory = workingDirectory }
        }
        guard let attachmentState = resolver.attachment(for: paneID) else {
            throw SSHError.unknown("Remote-session attachment was lost during startup")
        }

        let envelope = RemoteSessionLifecycleEnvelope.make()
        let intent: RemoteSessionLaunchIntent
        if isReattachingManagedSession
            || attachmentState.attachment.ownership == .external {
            intent = .attach(attachmentState.attachment)
        } else {
            intent = .ensureManaged(
                identifier: attachmentState.attachment.identifier,
                initialCommand: nil
            )
        }
        let backendPlan = try await remoteSessions.launchPlan(
            for: RemoteSessionLaunchRequest(
                intent: intent,
                workingDirectory: workingDirectory,
                initialCommand: mode == .attachOrCreate
                    ? startupAction?.command
                    : nil,
                lifecycleEnvelope: envelope,
                transport: transport,
                themeStyle: configuration.themeStyle()
            ),
            runtime: runtime
        )
        let lifecycle = RemoteSessionLifecycleContext(
            attachment: attachmentState.attachment,
            envelope: envelope,
            presenceProbe: backendPlan.presenceProbe
        )
        sessionState.updatePane(paneID, persist: true) {
            $0.remoteSessionResumeContext = lifecycle
        }
        return TerminalShellStartupPlan(
            command: backendPlan.command,
            remoteSessionLifecycle: lifecycle,
            mayExecuteUserStartupAction: mode == .attachOrCreate && startupAction != nil
        )
    }

    private func plainShellStartupPlan(
        _ action: RemoteShellStartupAction?
    ) -> TerminalShellStartupPlan {
        return TerminalShellStartupPlan(
            command: action?.command,
            remoteSessionLifecycle: nil,
            mayExecuteUserStartupAction: action != nil
        )
    }

    private func requireCurrentShellOwner(
        for paneID: UUID,
        client: SSHClient,
        startToken: SSHShellRegistry.StartToken
    ) throws {
        try Task.checkCancellation()
        guard sessionState.containsPane(paneID),
              transportLifetime.registry.ownsConnection(
                  client: client,
                  startToken: startToken,
                  for: paneID
              ) else {
            throw CancellationError()
        }
    }

    private func disableAttachment(for paneID: UUID, status: RemoteSessionStatus) {
        resolver.clearAttachmentState(for: paneID)
        clearResumeContext(for: paneID)
        updateStatus(status, for: paneID)
    }

    func clearResumeContext(for paneID: UUID) {
        sessionState.updatePane(paneID, persist: true) {
            $0.remoteSessionResumeContext = nil
        }
    }

    private func managedIdentifiers(
        backendIdentifier: RemoteSessionBackendIdentifier
    ) -> Set<RemoteSessionIdentifier> {
        // Several server profiles can share one remote host. Cleanup cannot
        // safely assign a listed remote name to one profile, so retain every
        // locally referenced identifier for this backend.
        Set(sessionState.allPaneStates.compactMap { paneState in
            guard let state = resolver.attachment(for: paneState.paneId),
                  state.attachment.ownership == .managed,
                  state.attachment.identifier.backendIdentifier == backendIdentifier else {
                return nil
            }
            return state.attachment.identifier
        })
    }

    private func runCleanupIfNeeded(
        for serverID: UUID,
        paneID: UUID,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async {
        let key = CleanupKey(
            serverID: serverID,
            backendIdentifier: runtime.backendIdentifier
        )
        guard completedCleanup.insert(key).inserted else { return }
        var identifiers = managedIdentifiers(
            backendIdentifier: runtime.backendIdentifier
        )
        if let identifier = resolver.attachment(for: paneID)?.attachment.identifier {
            identifiers.insert(identifier)
        }
        await remoteSessions.cleanupSessions(
            keeping: identifiers,
            using: client,
            runtime: runtime
        )
    }

    private func prepareActivePane(
        for paneID: UUID,
        serverID: UUID,
        using client: SSHClient,
        runtime: RemoteSessionRuntime
    ) async {
        let selectedTab = sessionState.selectedTab(for: serverID)
        let isForeground = selectedTab?.id == sessionState.selectedTabId(for: serverID)
            && selectedTab?.focusedPaneId == paneID
        updateStatus(isForeground ? .foreground : .background, for: paneID)
        let terminalType = await client.remoteTerminalType()
        await remoteSessions.prepareManagedSession(
            using: client,
            terminalType: terminalType,
            themeStyle: configuration.themeStyle(),
            runtime: runtime
        )
    }

    func resolveWorkingDirectory(
        for paneID: UUID,
        using client: SSHClient,
        runtime: RemoteSessionRuntime?
    ) async -> String {
        if let seedPaneID = sessionState.paneState(for: paneID)?.seedPaneId,
           let attachment = resolver.attachment(for: seedPaneID)?.attachment,
           let path = await remoteSessions.currentWorkingDirectory(
               for: attachment,
               using: client,
               runtime: runtime
           ) {
            return path
        }
        if let attachment = resolver.attachment(for: paneID)?.attachment,
           let path = await remoteSessions.currentWorkingDirectory(
               for: attachment,
               using: client,
               runtime: runtime
           ) {
            return path
        }
        if let candidate = sessionState.paneState(for: paneID)?.workingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !candidate.isEmpty {
            return candidate
        }
        return "~"
    }
}
