import Foundation
import Testing
@testable import VVTerm

struct ServerFormIntentTests {
    @Test
    func duplicateCopiesEditableFieldsWithFreshOwnership() throws {
        let sourceID = UUID()
        let duplicateID = UUID()
        let workspaceID = UUID()
        let sourceCreatedAt = Date(timeIntervalSince1970: 1_000)
        let sourceLastConnected = Date(timeIntervalSince1970: 2_000)
        let duplicateCreatedAt = Date(timeIntervalSince1970: 3_000)
        let source = Server(
            id: sourceID,
            workspaceId: workspaceID,
            environment: .staging,
            name: "Production",
            host: "host.example.com",
            port: 2_222,
            eternalTerminalPort: 20_222,
            username: "deploy",
            connectionMode: .cloudflare,
            authMethod: .sshKeyWithPassphrase,
            cloudflareAccessMode: .serviceToken,
            cloudflareTeamDomainOverride: "team.cloudflareaccess.com",
            cloudflareAppDomainOverride: "app.example.com",
            tags: ["customer"],
            notes: "Keep this note",
            lastConnected: sourceLastConnected,
            isFavorite: true,
            requiresBiometricUnlock: true,
            remoteSessionEnabledOverride: true,
            remoteSessionBackendIdentifier: .zmx,
            remoteSessionStartupBehaviorOverride: .createManaged,
            remoteShellStartupCommand: "cd /srv/app && exec $SHELL -l",
            createdAt: sourceCreatedAt
        )
        let intent = ServerFormIntent.duplicate(source)
        var form = ServerFormModel(
            server: source,
            defaultRemoteSessionEnabled: false,
            defaultRemoteSessionBackendIdentifier: .tmux,
            defaultRemoteSessionStartupBehavior: .ask
        )
        form.name = "Production Copy"
        var sourceCredentials = ServerCredentials(serverId: sourceID)
        sourceCredentials.privateKey = Data("PRIVATE".utf8)
        sourceCredentials.publicKey = Data("PUBLIC".utf8)
        sourceCredentials.passphrase = "phrase"
        sourceCredentials.cloudflareClientID = "client-id"
        sourceCredentials.cloudflareClientSecret = "client-secret"
        form.apply(sourceCredentials, for: source)

        let duplicate = intent.preservingSourceMetadata(
            in: form.makeServer(
                id: intent.serverID(makeID: { duplicateID }),
                workspaceID: try #require(form.workspaceID),
                createdAt: intent.createdAt(now: { duplicateCreatedAt })
            )
        )
        let duplicateCredentials = form.makeCredentials(serverID: duplicateID)

        #expect(duplicate.id == duplicateID)
        #expect(duplicate.id != source.id)
        #expect(duplicate.workspaceId == source.workspaceId)
        #expect(duplicate.environment == source.environment)
        #expect(duplicate.name == "Production Copy")
        #expect(duplicate.host == source.host)
        #expect(duplicate.port == source.port)
        #expect(duplicate.eternalTerminalPort == source.eternalTerminalPort)
        #expect(duplicate.username == source.username)
        #expect(duplicate.connectionMode == source.connectionMode)
        #expect(duplicate.authMethod == source.authMethod)
        #expect(duplicate.cloudflareAccessMode == source.cloudflareAccessMode)
        #expect(duplicate.cloudflareTeamDomainOverride == source.cloudflareTeamDomainOverride)
        #expect(duplicate.cloudflareAppDomainOverride == source.cloudflareAppDomainOverride)
        #expect(duplicate.tags == source.tags)
        #expect(duplicate.notes == source.notes)
        #expect(duplicate.isFavorite == source.isFavorite)
        #expect(duplicate.requiresBiometricUnlock == source.requiresBiometricUnlock)
        #expect(duplicate.remoteSessionEnabledOverride == source.remoteSessionEnabledOverride)
        #expect(duplicate.remoteSessionBackendIdentifier == source.remoteSessionBackendIdentifier)
        #expect(duplicate.remoteSessionStartupBehaviorOverride == source.remoteSessionStartupBehaviorOverride)
        #expect(duplicate.remoteShellStartupAction == source.remoteShellStartupAction)
        #expect(duplicate.createdAt == duplicateCreatedAt)
        #expect(duplicate.lastConnected == nil)
        #expect(duplicateCredentials.serverId == duplicateID)
        #expect(duplicateCredentials.serverId != sourceCredentials.serverId)
        #expect(duplicateCredentials.privateKey == sourceCredentials.privateKey)
        #expect(duplicateCredentials.publicKey == sourceCredentials.publicKey)
        #expect(duplicateCredentials.passphrase == sourceCredentials.passphrase)
        #expect(duplicateCredentials.cloudflareClientID == sourceCredentials.cloudflareClientID)
        #expect(duplicateCredentials.cloudflareClientSecret == sourceCredentials.cloudflareClientSecret)
        #expect(intent.mutation(for: duplicate) == .create(duplicate))
        #expect(source.lastConnected == sourceLastConnected)
        #expect(source.createdAt == sourceCreatedAt)
    }

    @Test
    func editKeepsIdentityAndRuntimeMetadata() {
        let source = Server(
            id: UUID(),
            workspaceId: UUID(),
            name: "Server",
            host: "example.com",
            username: "root",
            lastConnected: Date(timeIntervalSince1970: 1_000),
            createdAt: Date(timeIntervalSince1970: 500)
        )
        let intent = ServerFormIntent.edit(source)

        let result = intent.preservingSourceMetadata(in: source)

        #expect(intent.serverID(makeID: UUID.init) == source.id)
        #expect(intent.createdAt(now: Date.init) == source.createdAt)
        #expect(result.lastConnected == source.lastConnected)
        #expect(intent.mutation(for: result) == .update(result))
    }
}
