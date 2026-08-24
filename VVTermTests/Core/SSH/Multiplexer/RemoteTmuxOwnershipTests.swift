import Foundation
import Testing
@testable import VVTerm

struct RemoteTmuxOwnershipTests {
    @Test @MainActor
    func managedSessionNameUsesTheDerivedServerName() throws {
        let serverId = UUID()
        let resolver = RemoteSessionAttachResolver(
            configuration: configuration(serverID: serverId, serverName: "Prod API"),
            remoteSessions: UnavailableTerminalRemoteSessionService()
        )

        let identifier = try resolver.managedIdentifier(
            for: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            serverID: serverId,
            backendIdentifier: .tmux
        )

        #expect(identifier.rawValue.hasPrefix("vvterm-prod-api-d"))
    }

    @Test @MainActor
    func selectedVVTermManagedSessionKeepsManagedClearBehavior() throws {
        let resolver = makeResolver()
        let paneId = UUID()
        let serverId = UUID()
        let identifier = try resolver.managedIdentifier(
            for: paneId,
            serverID: serverId,
            backendIdentifier: .tmux
        )

        try resolver.updateAttachmentState(
            for: paneId,
            serverID: serverId,
            backendIdentifier: .tmux,
            selection: .attachExisting(identifier)
        )
        let ownership = try #require(resolver.attachment(for: paneId)?.attachment.ownership)
        let command = RemoteTmuxCommandBuilder.attachExistingCommand(
            themeStyle: deterministicRemoteSessionThemeStyle,
            sessionName: identifier.rawValue,
            ownership: ownership
        )

        #expect(ownership == .managed)
        #expect(command.contains("set-option -wq -t \"$vvtermWindow\" scroll-on-clear 'off'"))
        #expect(command.contains("set-hook -t '=\(identifier.rawValue):' 'after-new-window[1000]'"))
    }

    @Test @MainActor
    func selectedExternalSessionDoesNotLoadVVTermConfiguration() throws {
        let resolver = makeResolver()
        let paneId = UUID()
        let serverId = UUID()
        let identifier = try RemoteSessionIdentifier(
            backendIdentifier: .tmux,
            validating: "shared"
        )

        try resolver.updateAttachmentState(
            for: paneId,
            serverID: serverId,
            backendIdentifier: .tmux,
            selection: .attachExisting(identifier)
        )
        let ownership = try #require(resolver.attachment(for: paneId)?.attachment.ownership)
        let command = RemoteTmuxCommandBuilder.attachExistingCommand(
            themeStyle: deterministicRemoteSessionThemeStyle,
            sessionName: "shared",
            ownership: ownership
        )

        #expect(ownership == .external)
        #expect(!command.contains("source-file"))
        #expect(!command.contains("~/.vvterm/tmux.conf"))
    }

    @Test @MainActor
    func failedExternalSessionListingPreservesRememberedAttachment() async {
        let resolver = makeResolver()
        let paneId = UUID()
        let serverId = UUID()
        let identifier = try! RemoteSessionIdentifier(
            backendIdentifier: .tmux,
            validating: "shared-session"
        )
        resolver.setAttachment(
            TerminalRemoteSessionAttachmentState(
                attachment: RemoteSessionAttachment(
                    identifier: identifier,
                    ownership: .external
                ),
                managedSessionConfirmed: false
            ),
            for: paneId
        )

        do {
            _ = try await resolver.resolveSelection(
                for: paneId,
                serverID: serverId,
                client: SSHClient.testing(),
                runtime: runtime(),
                requestID: UUID(),
                validateOwner: {}
            )
            Issue.record("A failed session listing should remain a retryable connection error")
        } catch {
            #expect(error is SSHError)
        }

        #expect(resolver.attachment(for: paneId)?.attachment.identifier == identifier)
        #expect(resolver.attachment(for: paneId)?.attachment.ownership == .external)
    }

    @MainActor
    private func makeResolver() -> RemoteSessionAttachResolver {
        RemoteSessionAttachResolver(
            configuration: .testing,
            remoteSessions: UnavailableTerminalRemoteSessionService()
        )
    }

    @MainActor
    private func configuration(
        serverID: UUID,
        serverName: String
    ) -> TerminalRemoteSessionConfiguration {
        TerminalRemoteSessionConfiguration(
            deviceID: "test-device",
            enabledByDefault: { true },
            backendIdentifierByDefault: { .tmux },
            startupBehaviorByDefault: { .createManaged },
            serverSettings: { requestedID in
                guard requestedID == serverID else { return nil }
                return TerminalRemoteSessionConfiguration.ServerSettings(
                    name: serverName,
                    enabledOverride: true,
                    backendIdentifier: .tmux,
                    startupBehaviorOverride: .createManaged
                )
            },
            themeStyle: { deterministicRemoteSessionThemeStyle }
        )
    }

    private func runtime() -> RemoteSessionRuntime {
        RemoteSessionRuntime(probe: RemoteSessionProbe(
            backendIdentifier: .tmux,
            executable: try! RemoteSessionExecutable(validating: "/usr/bin/tmux"),
            implementationVariant: "tmux",
            rawVersion: "tmux 3.5a",
            semanticVersion: RemoteSessionSemanticVersion("3.5.0"),
            shellFamily: .posix,
            shellExecutable: "/bin/zsh"
        ))
    }
}
