import Foundation
import Testing
@testable import VVTerm

@MainActor
struct KeychainManagerSyncTests {
    @Test
    func enablingSyncCopiesEverySelectedCredentialBeforeRemovingLocalCopies() throws {
        let fixture = Fixture(syncEnabled: false)
        let server = makeServer(connectionMode: .cloudflare, authMethod: .sshKeyWithPassphrase)
        let reusableKeyID = UUID()
        let binding = try JSONEncoder().encode(ServerCredentialBinding(server: server))
        let index = try JSONEncoder().encode([
            SSHKeyEntry(id: reusableKeyID, name: "Reusable", hasPassphrase: true)
        ])
        let credentialValues: [String: Data] = [
            "server.\(server.id.uuidString).password": Data("password".utf8),
            "server.\(server.id.uuidString).sshkey": Data("private".utf8),
            "server.\(server.id.uuidString).passphrase": Data("passphrase".utf8),
            "server.\(server.id.uuidString).publickey": Data("public".utf8),
            "server.\(server.id.uuidString).cloudflare.clientid": Data("client-id".utf8),
            "server.\(server.id.uuidString).cloudflare.clientsecret": Data("client-secret".utf8),
            "server.\(server.id.uuidString).credential-binding.v1": binding,
            "vvterm.sshkeys.index": index,
            "sshkey.\(reusableKeyID.uuidString).data": Data("library-private".utf8),
            "sshkey.\(reusableKeyID.uuidString).passphrase": Data("library-passphrase".utf8)
        ]
        for (key, value) in credentialValues {
            try fixture.credentialStore.set(value, forKey: key, scope: .deviceOnly)
        }
        try fixture.credentialStore.set(
            Data("device-id".utf8),
            forKey: "vvterm.deviceId",
            scope: .deviceOnly
        )
        try fixture.oauthStore.set(
            Data("oauth-token".utf8),
            forKey: "oauth.example.com",
            scope: .deviceOnly
        )

        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        for (key, value) in credentialValues {
            #expect(try fixture.credentialStore.get(key, scope: .deviceOnly) == nil)
            #expect(try fixture.credentialStore.get(key, scope: .iCloud) == value)
        }
        #expect(
            try fixture.oauthStore.get("oauth.example.com", scope: .iCloud)
                == Data("oauth-token".utf8)
        )
        #expect(
            try fixture.oauthStore.get("oauth.example.com", scope: .deviceOnly) == nil
        )
        #expect(
            try fixture.credentialStore.get("vvterm.deviceId", scope: .iCloud) == nil
        )
    }

    @Test
    func disablingSyncCopiesCloudCredentialsWithoutRemovingOtherDevicesCopy() throws {
        let fixture = Fixture(syncEnabled: true)
        let key = "server.\(UUID().uuidString).password"
        let value = Data("cloud-password".utf8)
        try fixture.credentialStore.set(value, forKey: key, scope: .iCloud)
        try fixture.oauthStore.set(
            Data("oauth-token".utf8),
            forKey: "oauth.example.com",
            scope: .iCloud
        )

        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)

        #expect(try fixture.credentialStore.get(key, scope: .deviceOnly) == value)
        #expect(try fixture.credentialStore.get(key, scope: .iCloud) == value)
        #expect(
            try fixture.oauthStore.get("oauth.example.com", scope: .deviceOnly)
                == Data("oauth-token".utf8)
        )
        #expect(
            try fixture.oauthStore.get("oauth.example.com", scope: .iCloud)
                == Data("oauth-token".utf8)
        )
    }

    @Test
    func failedEnableCopyPreservesTheLocalCredential() throws {
        let fixture = Fixture(syncEnabled: false)
        let key = "server.\(UUID().uuidString).password"
        let value = Data("local-password".utf8)
        try fixture.credentialStore.set(value, forKey: key, scope: .deviceOnly)
        fixture.backing.failWrites(to: .iCloud)

        #expect(throws: InMemoryKeychainStoreBacking.Failure.writeRejected) {
            try fixture.manager.synchronizeCredentialStorage(isEnabled: true)
        }
        #expect(try fixture.credentialStore.get(key, scope: .deviceOnly) == value)
        #expect(try fixture.credentialStore.get(key, scope: .iCloud) == nil)
    }

    @Test
    func failedEnableVerificationPreservesTheDeviceOnlyCredential() throws {
        let fixture = Fixture(syncEnabled: false)
        let key = "server.\(UUID().uuidString).password"
        let value = Data("local-password".utf8)
        try fixture.credentialStore.set(value, forKey: key, scope: .deviceOnly)
        fixture.backing.corruptReads(
            from: .iCloud,
            service: KeychainManager.credentialService,
            key: key
        )

        do {
            try fixture.manager.synchronizeCredentialStorage(isEnabled: true)
            Issue.record("Expected copy verification to fail")
        } catch KeychainError.copyVerificationFailed {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try fixture.credentialStore.get(key, scope: .deviceOnly) == value)
    }

    @Test
    func failedOAuthCopyPreservesCredentialsAlreadyCopiedToICloud() throws {
        let fixture = Fixture(syncEnabled: false)
        let credentialKey = "server.\(UUID().uuidString).password"
        let oauthKey = "oauth.example.com"
        let credential = Data("local-password".utf8)
        let oauth = Data("local-oauth".utf8)
        try fixture.credentialStore.set(
            credential,
            forKey: credentialKey,
            scope: .deviceOnly
        )
        try fixture.oauthStore.set(oauth, forKey: oauthKey, scope: .deviceOnly)
        fixture.backing.failWrites(
            to: .iCloud,
            service: KeychainManager.cloudflareTokenService,
            key: oauthKey
        )

        #expect(throws: InMemoryKeychainStoreBacking.Failure.writeRejected) {
            try fixture.manager.synchronizeCredentialStorage(isEnabled: true)
        }

        #expect(try fixture.credentialStore.get(credentialKey, scope: .deviceOnly) == credential)
        #expect(try fixture.credentialStore.get(credentialKey, scope: .iCloud) == credential)
        #expect(try fixture.oauthStore.get(oauthKey, scope: .deviceOnly) == oauth)
        #expect(try fixture.oauthStore.get(oauthKey, scope: .iCloud) == nil)
    }

    @Test
    func explicitCloudRemovalKeepsDeviceOnlyCredentials() throws {
        let fixture = Fixture(syncEnabled: false)
        let key = "server.\(UUID().uuidString).password"
        let local = Data("local-password".utf8)
        try fixture.credentialStore.set(local, forKey: key, scope: .deviceOnly)
        try fixture.credentialStore.set(
            Data("cloud-password".utf8),
            forKey: key,
            scope: .iCloud
        )
        try fixture.oauthStore.set(
            Data("oauth-token".utf8),
            forKey: "oauth.example.com",
            scope: .iCloud
        )

        try fixture.manager.removeCredentialsFromICloud()

        #expect(try fixture.credentialStore.get(key, scope: .deviceOnly) == local)
        #expect(try fixture.credentialStore.get(key, scope: .iCloud) == nil)
        #expect(try fixture.oauthStore.get("oauth.example.com", scope: .iCloud) == nil)
    }

    @Test
    func disabledSyncDoesNotReadTheCopyOwnedByOtherDevices() throws {
        let fixture = Fixture(syncEnabled: false)
        let server = makeServer(connectionMode: .standard, authMethod: .password)
        let prefix = "server.\(server.id.uuidString)"
        try fixture.credentialStore.set(
            Data("cloud-password".utf8),
            forKey: "\(prefix).password",
            scope: .iCloud
        )
        try fixture.credentialStore.set(
            try JSONEncoder().encode(ServerCredentialBinding(server: server)),
            forKey: "\(prefix).credential-binding.v1",
            scope: .iCloud
        )

        let credentials = try fixture.manager.getCredentials(for: server)

        #expect(credentials.password == nil)
        #expect(!(try fixture.manager.hasCredentials(for: server)))
    }

    @Test
    func unchangedOfflineSnapshotDoesNotOverwriteNewerCloudCredentials() throws {
        let fixture = Fixture(syncEnabled: false)
        let server = makeServer(connectionMode: .standard, authMethod: .password)
        let passwordKey = "server.\(server.id.uuidString).password"
        let bindingKey = "server.\(server.id.uuidString).credential-binding.v1"
        let binding = try JSONEncoder().encode(ServerCredentialBinding(server: server))
        try fixture.credentialStore.set(Data("P1".utf8), forKey: passwordKey, scope: .iCloud)
        try fixture.credentialStore.set(binding, forKey: bindingKey, scope: .iCloud)

        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        try fixture.credentialStore.set(Data("P2".utf8), forKey: passwordKey, scope: .iCloud)
        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        #expect(try fixture.credentialStore.get(passwordKey, scope: .iCloud) == Data("P2".utf8))
        #expect(try fixture.credentialStore.get(passwordKey, scope: .deviceOnly) == nil)
    }

    @Test
    func explicitOfflineUpdateReplacesCloudCredentialBundle() throws {
        let fixture = Fixture(syncEnabled: false)
        let server = makeServer(connectionMode: .standard, authMethod: .password)
        let passwordKey = "server.\(server.id.uuidString).password"
        let bindingKey = "server.\(server.id.uuidString).credential-binding.v1"
        let binding = try JSONEncoder().encode(ServerCredentialBinding(server: server))
        try fixture.credentialStore.set(Data("P1".utf8), forKey: passwordKey, scope: .iCloud)
        try fixture.credentialStore.set(binding, forKey: bindingKey, scope: .iCloud)

        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        try fixture.credentialStore.set(Data("P2".utf8), forKey: passwordKey, scope: .iCloud)
        try fixture.manager.storeCredentials(
            ServerCredentials(serverId: server.id, password: "P3"),
            for: server
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        #expect(try fixture.credentialStore.get(passwordKey, scope: .iCloud) == Data("P3".utf8))
        #expect(try fixture.credentialStore.get(bindingKey, scope: .iCloud) == binding)
        #expect(try fixture.credentialStore.get(passwordKey, scope: .deviceOnly) == nil)
    }

    @Test
    func explicitOfflineDeletionCannotReturnWhenSyncIsEnabled() throws {
        let fixture = Fixture(syncEnabled: false)
        let server = makeServer(connectionMode: .standard, authMethod: .password)
        let passwordKey = "server.\(server.id.uuidString).password"
        let bindingKey = "server.\(server.id.uuidString).credential-binding.v1"
        let binding = try JSONEncoder().encode(ServerCredentialBinding(server: server))
        try fixture.credentialStore.set(Data("P1".utf8), forKey: passwordKey, scope: .iCloud)
        try fixture.credentialStore.set(binding, forKey: bindingKey, scope: .iCloud)

        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        try fixture.manager.deleteCredentials(for: server.id)
        try fixture.credentialStore.set(Data("stale".utf8), forKey: passwordKey, scope: .iCloud)
        try fixture.credentialStore.set(binding, forKey: bindingKey, scope: .iCloud)
        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        #expect(try fixture.credentialStore.get(passwordKey, scope: .iCloud) == nil)
        #expect(try fixture.credentialStore.get(bindingKey, scope: .iCloud) == nil)
        #expect(try fixture.credentialStore.get(passwordKey, scope: .deviceOnly) == nil)
    }

    @Test
    func failedOfflineDeletionRemainsPendingUntilCleanupSucceeds() throws {
        let fixture = Fixture(syncEnabled: false)
        let server = makeServer(connectionMode: .standard, authMethod: .password)
        let passwordKey = "server.\(server.id.uuidString).password"
        let bindingKey = "server.\(server.id.uuidString).credential-binding.v1"
        let binding = try JSONEncoder().encode(ServerCredentialBinding(server: server))
        try fixture.credentialStore.set(Data("P1".utf8), forKey: passwordKey, scope: .iCloud)
        try fixture.credentialStore.set(binding, forKey: bindingKey, scope: .iCloud)
        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)
        fixture.backing.failDeletes(
            from: .iCloud,
            service: KeychainManager.credentialService,
            key: passwordKey
        )

        #expect(throws: InMemoryKeychainStoreBacking.Failure.deleteRejected) {
            try fixture.manager.deleteCredentials(for: server.id)
        }
        #expect(fixture.offlineChanges.change(for: .server(server.id)) == .deleted)

        fixture.backing.allowDeletes(
            from: .iCloud,
            service: KeychainManager.credentialService,
            key: passwordKey
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        #expect(try fixture.credentialStore.get(passwordKey, scope: .iCloud) == nil)
        #expect(try fixture.credentialStore.get(bindingKey, scope: .iCloud) == nil)
        #expect(fixture.offlineChanges.change(for: .server(server.id)) == nil)
        #expect(!fixture.offlineChanges.isTrackingOfflineChanges)
    }

    @Test
    func synchronizedWritesIncludeBindingsAndAllServerCredentialFields() throws {
        let fixture = Fixture(syncEnabled: true)
        let passwordServer = makeServer(
            connectionMode: .standard,
            authMethod: .password
        )
        try fixture.manager.storeCredentials(
            ServerCredentials(serverId: passwordServer.id, password: "password"),
            for: passwordServer
        )
        let server = makeServer(
            connectionMode: .cloudflare,
            authMethod: .sshKeyWithPassphrase
        )
        let credentials = ServerCredentials(
            serverId: server.id,
            privateKey: Data("private".utf8),
            publicKey: Data("public".utf8),
            passphrase: "passphrase",
            cloudflareClientID: "client-id",
            cloudflareClientSecret: "client-secret"
        )

        try fixture.manager.storeCredentials(credentials, for: server)
        let reusableKey = try fixture.manager.storeSSHKeyEntry(
            name: "Reusable",
            privateKey: Data("library-private".utf8),
            passphrase: "library-passphrase"
        )

        let prefix = "server.\(server.id.uuidString)"
        for key in [
            "server.\(passwordServer.id.uuidString).password",
            "server.\(passwordServer.id.uuidString).credential-binding.v1",
            "\(prefix).sshkey",
            "\(prefix).passphrase",
            "\(prefix).publickey",
            "\(prefix).cloudflare.clientid",
            "\(prefix).cloudflare.clientsecret",
            "\(prefix).credential-binding.v1",
            "vvterm.sshkeys.index",
            "sshkey.\(reusableKey.id.uuidString).data",
            "sshkey.\(reusableKey.id.uuidString).passphrase"
        ] {
            #expect(try fixture.credentialStore.contains(key, scope: .iCloud))
            #expect(!(try fixture.credentialStore.contains(key, scope: .deviceOnly)))
        }
    }

    @Test
    func loadingCredentialsAutomaticallyRebindsThemToTheCurrentServerEndpoint() throws {
        let fixture = Fixture(syncEnabled: true)
        let originalServer = makeServer(connectionMode: .standard, authMethod: .password)
        var server = originalServer
        server.host = "changed.example.com"
        let prefix = "server.\(server.id.uuidString)"
        try fixture.credentialStore.set(
            Data("cloud-password".utf8),
            forKey: "\(prefix).password",
            scope: .iCloud
        )
        try fixture.credentialStore.set(
            try JSONEncoder().encode(ServerCredentialBinding(server: originalServer)),
            forKey: "\(prefix).credential-binding.v1",
            scope: .iCloud
        )

        let credentials = try fixture.manager.getCredentials(for: server)

        #expect(credentials.password == "cloud-password")
        #expect(credentials.credentialBinding == ServerCredentialBinding(server: server))
        let storedBindingData = try fixture.credentialStore.get(
            "\(prefix).credential-binding.v1",
            scope: .iCloud
        )
        let boundData = try #require(storedBindingData)
        #expect(
            try JSONDecoder().decode(ServerCredentialBinding.self, from: boundData)
                == ServerCredentialBinding(server: server)
        )
    }

    @Test
    func differentServerUUIDDoesNotInheritCredentialsFromAnEquivalentServer() throws {
        let fixture = Fixture(syncEnabled: true)
        let original = makeServer(connectionMode: .standard, authMethod: .password)
        let duplicate = makeServer(connectionMode: .standard, authMethod: .password)
        try fixture.manager.storeCredentials(
            ServerCredentials(serverId: original.id, password: "original-password"),
            for: original
        )

        let duplicateCredentials = try fixture.manager.getCredentials(for: duplicate)

        #expect(original.id != duplicate.id)
        #expect(duplicateCredentials.password == nil)
        #expect(!(try fixture.manager.hasCredentials(for: duplicate)))
    }

    @Test
    func oauthTokenWritesUseTheSelectedSyncScope() async throws {
        let backing = InMemoryKeychainStoreBacking()
        let store = KeychainStore(
            service: KeychainManager.cloudflareTokenService,
            backing: backing
        )
        let syncedAdapter = CloudflareTokenStoreAdapter(
            store: store,
            isSyncEnabled: { true }
        )
        try await syncedAdapter.writeToken("cloud-token", for: "cloud")

        let localAdapter = CloudflareTokenStoreAdapter(
            store: store,
            isSyncEnabled: { false }
        )
        try await localAdapter.writeToken("local-token", for: "local")

        #expect(try store.getString("oauth.cloud", scope: .iCloud) == "cloud-token")
        #expect(
            try store.getString("oauth.local", scope: .deviceOnly) == "local-token"
        )
    }

    @Test
    func offlineOAuthDeletionRemainsDeletedAfterEnable() async throws {
        let fixture = Fixture(syncEnabled: false)
        let adapter = CloudflareTokenStoreAdapter(
            store: fixture.oauthStore,
            isSyncEnabled: { false },
            offlineChanges: fixture.offlineChanges
        )
        try fixture.oauthStore.setString(
            "cloud-token",
            forKey: "oauth.example",
            scope: .iCloud
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: false)

        try await adapter.removeToken(for: "example")
        try fixture.oauthStore.setString(
            "stale-token",
            forKey: "oauth.example",
            scope: .iCloud
        )
        try fixture.manager.synchronizeCredentialStorage(isEnabled: true)

        #expect(try fixture.oauthStore.getString("oauth.example", scope: .iCloud) == nil)
        #expect(try fixture.oauthStore.getString("oauth.example", scope: .deviceOnly) == nil)
    }

    @MainActor
    private final class Fixture {
        let backing = InMemoryKeychainStoreBacking()
        let credentialStore: KeychainStore
        let oauthStore: KeychainStore
        let offlineChanges: CredentialOfflineChangeStore
        let manager: KeychainManager
        private let defaults: UserDefaults

        init(syncEnabled: Bool) {
            let suiteName = "KeychainManagerSyncTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            offlineChanges = CredentialOfflineChangeStore(defaults: defaults)
            credentialStore = KeychainStore(
                service: KeychainManager.credentialService,
                backing: backing
            )
            oauthStore = KeychainStore(
                service: KeychainManager.cloudflareTokenService,
                backing: backing
            )
            manager = KeychainManager(
                store: credentialStore,
                cloudflareTokenStore: oauthStore,
                isSyncEnabled: { syncEnabled },
                offlineChanges: offlineChanges
            )
        }
    }

    private func makeServer(
        connectionMode: SSHConnectionMode,
        authMethod: AuthMethod
    ) -> Server {
        Server(
            workspaceId: UUID(),
            name: "Server",
            host: "example.com",
            port: 22,
            username: "root",
            connectionMode: connectionMode,
            authMethod: authMethod,
            cloudflareAccessMode: connectionMode == .cloudflare ? .serviceToken : nil,
            cloudflareTeamDomainOverride: connectionMode == .cloudflare
                ? "team.cloudflareaccess.com"
                : nil,
            cloudflareAppDomainOverride: connectionMode == .cloudflare
                ? "app.example.com"
                : nil
        )
    }
}
