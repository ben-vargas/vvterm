import Foundation
import os.log

// MARK: - Keychain Manager

@MainActor
final class KeychainManager {
    nonisolated static let credentialService = "app.vivy.vvterm"
    nonisolated static let cloudflareTokenService = "app.vivy.vvterm.cloudflare.tokens"
    nonisolated static let iCloudMigrationKey = "vvterm.keychain.iCloudMigration.v1"

    static let shared = KeychainManager(performsInitialMigration: true)

    private let store: KeychainStore
    private let cloudflareTokenStore: KeychainStore
    private let isSyncEnabled: @Sendable () -> Bool
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Keychain")

    init(
        store: KeychainStore = KeychainStore(service: credentialService),
        cloudflareTokenStore: KeychainStore = KeychainStore(
            service: cloudflareTokenService
        ),
        isSyncEnabled: @escaping @Sendable () -> Bool = { SyncSettings.isEnabled },
        performsInitialMigration: Bool = false
    ) {
        self.store = store
        self.cloudflareTokenStore = cloudflareTokenStore
        self.isSyncEnabled = isSyncEnabled
        if performsInitialMigration,
           isSyncEnabled(),
           !UserDefaults.standard.bool(forKey: Self.iCloudMigrationKey) {
            do {
                try synchronizeCredentialStorage(isEnabled: true)
                UserDefaults.standard.set(true, forKey: Self.iCloudMigrationKey)
            } catch {
                logger.error("Could not prepare credential sync: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Password Operations

    private func storePassword(
        for serverId: UUID,
        password: String,
        scope: KeychainStorageScope
    ) throws {
        let key = passwordKey(for: serverId)
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try store.set(data, forKey: key, scope: scope)
        logger.info("Stored password for server \(serverId.uuidString)")
    }

    private func getPassword(
        for serverId: UUID,
        scope: KeychainStorageScope
    ) throws -> String? {
        let key = passwordKey(for: serverId)

        // Try store first
        if let data = try store.get(key, scope: scope) {
            guard let password = String(data: data, encoding: .utf8) else {
                throw KeychainError.decodingFailed
            }
            return password
        }

        return nil
    }

    // MARK: - SSH Key Operations

    private func storeSSHKey(
        for serverId: UUID,
        privateKey: Data,
        passphrase: String?,
        publicKey: Data? = nil,
        scope: KeychainStorageScope
    ) throws {
        let keyKey = sshKeyKey(for: serverId)
        try store.set(privateKey, forKey: keyKey, scope: scope)

        if let passphrase = passphrase {
            let passphraseKey = sshPassphraseKey(for: serverId)
            guard let passphraseData = passphrase.data(using: .utf8) else {
                throw KeychainError.encodingFailed
            }
            try store.set(passphraseData, forKey: passphraseKey, scope: scope)
        }

        let publicKeyKey = sshPublicKeyKey(for: serverId)
        if let publicKey, !publicKey.isEmpty {
            try store.set(publicKey, forKey: publicKeyKey, scope: scope)
        } else {
            try? store.delete(publicKeyKey, scope: scope)
        }

        logger.info("Stored SSH key for server \(serverId.uuidString)")
    }

    private func getSSHKey(
        for serverId: UUID,
        scope: KeychainStorageScope
    ) throws -> (key: Data, passphrase: String?, publicKey: Data?)? {
        let keyKey = sshKeyKey(for: serverId)
        let passphraseKey = sshPassphraseKey(for: serverId)
        let publicKeyKey = sshPublicKeyKey(for: serverId)

        // Try store first
        if let keyData = try store.get(keyKey, scope: scope) {
            var passphrase: String? = nil
            if let passphraseData = try store.get(passphraseKey, scope: scope) {
                passphrase = String(data: passphraseData, encoding: .utf8)
            }
            let publicKeyData = try store.get(publicKeyKey, scope: scope)
            return (key: keyData, passphrase: passphrase, publicKey: publicKeyData)
        }

        return nil
    }

    // MARK: - Full Credentials

    func getCredentials(for server: Server) throws -> ServerCredentials {
        var credentials = ServerCredentials(
            serverId: server.id,
            credentialBinding: ServerCredentialBinding(server: server)
        )

        logger.info("Getting credentials for server \(server.id.uuidString), authMethod: \(String(describing: server.authMethod))")

        if server.connectionMode == .tailscale {
            logger.info("Server \(server.id.uuidString) uses tailscale mode; skipping keychain credential lookup")
            return credentials
        }

        let resolution = try credentialStorageResolution(for: server)
        guard resolution?.status != .approvalRequired else {
            logger.warning("Blocked credentials for a changed server endpoint: \(server.id.uuidString)")
            throw ServerCredentialAccessError.approvalRequired
        }
        let scope = resolution?.scope ?? preferredStorageScope

        switch server.authMethod {
        case .password:
            credentials.password = try getPassword(for: server.id, scope: scope)
            logger.info("Password retrieved: \(credentials.password != nil)")
        case .sshKey:
            if let sshData = try getSSHKey(for: server.id, scope: scope) {
                credentials.privateKey = sshData.key
                credentials.publicKey = sshData.publicKey
            }
        case .sshKeyWithPassphrase:
            if let sshData = try getSSHKey(for: server.id, scope: scope) {
                credentials.privateKey = sshData.key
                credentials.passphrase = sshData.passphrase
                credentials.publicKey = sshData.publicKey
            }
        }

        if server.connectionMode == .cloudflare, server.cloudflareAccessMode == .serviceToken,
           let cloudflareToken = try getCloudflareServiceToken(
               for: server.id,
               scope: scope
           ) {
            credentials.cloudflareClientID = cloudflareToken.clientID
            credentials.cloudflareClientSecret = cloudflareToken.clientSecret
        }

        return credentials
    }

    func storeCredentials(_ credentials: ServerCredentials, for server: Server) throws {
        guard credentials.serverId == server.id else {
            throw KeychainError.credentialServerMismatch
        }

        let scope = preferredStorageScope
        if server.connectionMode != .tailscale {
            switch server.authMethod {
            case .password:
                if let password = credentials.password {
                    try storePassword(
                        for: server.id,
                        password: password,
                        scope: scope
                    )
                }
            case .sshKey, .sshKeyWithPassphrase:
                if let privateKey = credentials.privateKey {
                    try storeSSHKey(
                        for: server.id,
                        privateKey: privateKey,
                        passphrase: credentials.passphrase,
                        publicKey: credentials.publicKey,
                        scope: scope
                    )
                }
            }
        }

        if server.connectionMode == .cloudflare,
           server.cloudflareAccessMode == .serviceToken,
           let clientID = credentials.cloudflareClientID,
           let clientSecret = credentials.cloudflareClientSecret {
            try storeCloudflareServiceToken(
                for: server.id,
                clientID: clientID,
                clientSecret: clientSecret,
                scope: scope
            )
        } else {
            deleteCloudflareServiceToken(for: server.id)
        }

        try approveCredentialUse(for: server, scope: scope)
    }

    func credentialBindingStatus(for server: Server) throws -> ServerCredentialBindingStatus {
        try credentialStorageResolution(for: server)?.status ?? .noCredentials
    }

    func approveCredentialUse(for server: Server) throws {
        guard let resolution = try credentialStorageResolution(for: server) else {
            try? store.delete(
                credentialBindingKey(for: server.id),
                scope: preferredStorageScope
            )
            return
        }

        try approveCredentialUse(for: server, scope: resolution.scope)
    }

    private func approveCredentialUse(
        for server: Server,
        scope: KeychainStorageScope
    ) throws {
        let binding = ServerCredentialBinding(server: server)
        let data = try JSONEncoder().encode(binding)
        try store.set(
            data,
            forKey: credentialBindingKey(for: server.id),
            scope: scope
        )
        logger.info("Approved credential endpoint for server \(server.id.uuidString)")
    }

    // MARK: - Cloudflare Service Token

    private func storeCloudflareServiceToken(
        for serverId: UUID,
        clientID: String,
        clientSecret: String,
        scope: KeychainStorageScope
    ) throws {
        let idKey = cloudflareClientIDKey(for: serverId)
        let secretKey = cloudflareClientSecretKey(for: serverId)

        guard let idData = clientID.data(using: .utf8),
              let secretData = clientSecret.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        try store.set(idData, forKey: idKey, scope: scope)
        try store.set(secretData, forKey: secretKey, scope: scope)
        logger.info("Stored Cloudflare service token for server \(serverId.uuidString)")
    }

    private func getCloudflareServiceToken(
        for serverId: UUID,
        scope: KeychainStorageScope
    ) throws -> (clientID: String, clientSecret: String)? {
        let idKey = cloudflareClientIDKey(for: serverId)
        let secretKey = cloudflareClientSecretKey(for: serverId)

        guard let idData = try store.get(idKey, scope: scope),
              let secretData = try store.get(secretKey, scope: scope),
              let clientID = String(data: idData, encoding: .utf8),
              let clientSecret = String(data: secretData, encoding: .utf8) else {
            return nil
        }

        return (clientID: clientID, clientSecret: clientSecret)
    }

    private func deleteCloudflareServiceToken(for serverId: UUID) {
        deleteCredentialKey(cloudflareClientIDKey(for: serverId))
        deleteCredentialKey(cloudflareClientSecretKey(for: serverId))
    }

    // MARK: - Delete Operations

    func deleteCredentials(for serverId: UUID) throws {
        let passwordKey = passwordKey(for: serverId)
        let keyKey = sshKeyKey(for: serverId)
        let passphraseKey = sshPassphraseKey(for: serverId)
        let publicKeyKey = sshPublicKeyKey(for: serverId)
        let cloudflareIDKey = cloudflareClientIDKey(for: serverId)
        let cloudflareSecretKey = cloudflareClientSecretKey(for: serverId)
        let bindingKey = credentialBindingKey(for: serverId)

        for key in [
            passwordKey,
            keyKey,
            passphraseKey,
            publicKeyKey,
            cloudflareIDKey,
            cloudflareSecretKey,
            bindingKey
        ] {
            deleteCredentialKey(key)
        }

        logger.info("Deleted credentials for server \(serverId.uuidString)")
    }

    // MARK: - Key Generation

    private func passwordKey(for serverId: UUID) -> String {
        "server.\(serverId.uuidString).password"
    }

    private func sshKeyKey(for serverId: UUID) -> String {
        "server.\(serverId.uuidString).sshkey"
    }

    private func sshPassphraseKey(for serverId: UUID) -> String {
        "server.\(serverId.uuidString).passphrase"
    }

    private func sshPublicKeyKey(for serverId: UUID) -> String {
        "server.\(serverId.uuidString).publickey"
    }

    private func cloudflareClientIDKey(for serverId: UUID) -> String {
        "server.\(serverId.uuidString).cloudflare.clientid"
    }

    private func cloudflareClientSecretKey(for serverId: UUID) -> String {
        "server.\(serverId.uuidString).cloudflare.clientsecret"
    }

    private func credentialBindingKey(for serverId: UUID) -> String {
        "server.\(serverId.uuidString).credential-binding.v1"
    }

    private func credentialKeys(for serverId: UUID) -> [String] {
        [
            passwordKey(for: serverId),
            sshKeyKey(for: serverId),
            sshPassphraseKey(for: serverId),
            sshPublicKeyKey(for: serverId),
            cloudflareClientIDKey(for: serverId),
            cloudflareClientSecretKey(for: serverId)
        ]
    }

    private struct CredentialStorageResolution {
        let scope: KeychainStorageScope
        let status: ServerCredentialBindingStatus
    }

    private var preferredStorageScope: KeychainStorageScope {
        isSyncEnabled() ? .iCloud : .deviceOnly
    }

    private var readScopes: [KeychainStorageScope] {
        isSyncEnabled() ? [.iCloud, .deviceOnly] : [.deviceOnly]
    }

    private var credentialDeletionScopes: [KeychainStorageScope] {
        isSyncEnabled() ? [.iCloud, .deviceOnly] : [.deviceOnly]
    }

    private func credentialStorageResolution(
        for server: Server
    ) throws -> CredentialStorageResolution? {
        let currentBinding = ServerCredentialBinding(server: server)
        var firstStoredResolution: CredentialStorageResolution?

        for scope in readScopes {
            let hasCredentials = try credentialKeys(for: server.id).contains { key in
                try store.contains(key, scope: scope)
            }
            guard hasCredentials else { continue }

            let storedBinding: ServerCredentialBinding?
            if let data = try store.get(
                credentialBindingKey(for: server.id),
                scope: scope
            ) {
                storedBinding = try? JSONDecoder().decode(
                    ServerCredentialBinding.self,
                    from: data
                )
            } else {
                storedBinding = nil
            }
            let resolution = CredentialStorageResolution(
                scope: scope,
                status: ServerCredentialBindingStatus.resolve(
                    storedBinding: storedBinding,
                    currentBinding: currentBinding,
                    hasStoredCredentials: true
                )
            )
            if resolution.status == .matches {
                return resolution
            }
            if firstStoredResolution == nil {
                firstStoredResolution = resolution
            }
        }

        return firstStoredResolution
    }

    private func deleteCredentialKey(_ key: String) {
        for scope in credentialDeletionScopes {
            try? store.delete(key, scope: scope)
        }
    }

    func synchronizeCredentialStorage(isEnabled: Bool) throws {
        let source: KeychainStorageScope = isEnabled ? .deviceOnly : .iCloud
        let destination: KeychainStorageScope = isEnabled ? .iCloud : .deviceOnly

        try store.copyAll(
            from: source,
            to: destination,
            where: Self.isSynchronizableCredentialKey
        )
        try cloudflareTokenStore.copyAll(
            from: source,
            to: destination,
            where: { $0.hasPrefix("oauth.") }
        )

        if isEnabled {
            try store.deleteAll(
                in: source,
                where: Self.isSynchronizableCredentialKey
            )
            try cloudflareTokenStore.deleteAll(
                in: source,
                where: { $0.hasPrefix("oauth.") }
            )
        }
        logger.info(
            "Prepared credential storage for iCloud sync enabled=\(isEnabled)"
        )
    }

    func handleSyncToggle(isEnabled: Bool) throws {
        try synchronizeCredentialStorage(isEnabled: isEnabled)
        if isEnabled {
            UserDefaults.standard.set(true, forKey: Self.iCloudMigrationKey)
        }
    }

    func removeCredentialsFromICloud() throws {
        try store.deleteAll(
            in: .iCloud,
            where: Self.isSynchronizableCredentialKey
        )
        try cloudflareTokenStore.deleteAll(
            in: .iCloud,
            where: { $0.hasPrefix("oauth.") }
        )
        logger.info("Removed VVTerm credentials from iCloud Keychain")
    }

    nonisolated static func isSynchronizableCredentialKey(_ key: String) -> Bool {
        if key == "vvterm.sshkeys.index" {
            return true
        }
        if key.hasPrefix("sshkey.") {
            return key.hasSuffix(".data") || key.hasSuffix(".passphrase")
        }
        guard key.hasPrefix("server.") else { return false }
        return [
            ".password",
            ".sshkey",
            ".passphrase",
            ".publickey",
            ".cloudflare.clientid",
            ".cloudflare.clientsecret",
            ".credential-binding.v1"
        ].contains { key.hasSuffix($0) }
    }

    // MARK: - Reusable SSH Keys (Keychain Library)

    private let sshKeysIndexKey = "vvterm.sshkeys.index"

    /// Get all stored SSH key entries (metadata only, not the actual keys)
    func getStoredSSHKeys() -> [SSHKeyEntry] {
        for scope in readScopes {
            if let data = try? store.get(sshKeysIndexKey, scope: scope),
               let keys = try? JSONDecoder().decode([SSHKeyEntry].self, from: data) {
                return keys.sorted { $0.createdAt > $1.createdAt }
            }
        }
        return []
    }

    /// Save the SSH key index
    private func saveSSHKeysIndex(_ keys: [SSHKeyEntry]) throws {
        let data = try JSONEncoder().encode(keys)
        try store.set(data, forKey: sshKeysIndexKey, scope: preferredStorageScope)
    }

    /// Store a new SSH key in the keychain library
    func storeSSHKeyEntry(
        name: String,
        privateKey: Data,
        passphrase: String?,
        keyType: SSHKeyType? = nil,
        publicKey: String? = nil
    ) throws -> SSHKeyEntry {
        let entry = SSHKeyEntry(
            name: name,
            hasPassphrase: passphrase != nil && !passphrase!.isEmpty,
            createdAt: Date(),
            keyType: keyType,
            publicKey: publicKey
        )

        // Store the actual key data
        try store.set(
            privateKey,
            forKey: storedKeyDataKey(for: entry.id),
            scope: preferredStorageScope
        )

        // Store passphrase if provided
        if let passphrase = passphrase, !passphrase.isEmpty,
           let passphraseData = passphrase.data(using: .utf8) {
            try store.set(
                passphraseData,
                forKey: storedKeyPassphraseKey(for: entry.id),
                scope: preferredStorageScope
            )
        }

        // Update index
        var keys = getStoredSSHKeys()
        keys.append(entry)
        try saveSSHKeysIndex(keys)

        logger.info("Stored SSH key '\(name)' in keychain library")
        return entry
    }

    /// Get the actual key data for a stored SSH key
    func getStoredSSHKeyData(for keyId: UUID) throws -> (key: Data, passphrase: String?)? {
        var storedScope: KeychainStorageScope?
        var storedKeyData: Data?
        for scope in readScopes {
            if let keyData = try store.get(storedKeyDataKey(for: keyId), scope: scope) {
                storedScope = scope
                storedKeyData = keyData
                break
            }
        }
        guard let scope = storedScope, let keyData = storedKeyData else { return nil }

        var passphrase: String? = nil
        if let passphraseData = try store.get(
            storedKeyPassphraseKey(for: keyId),
            scope: scope
        ) {
            passphrase = String(data: passphraseData, encoding: .utf8)
        }

        return (key: keyData, passphrase: passphrase)
    }

    /// Delete a stored SSH key from the library
    func deleteStoredSSHKey(_ keyId: UUID) throws {
        // Delete key data
        deleteCredentialKey(storedKeyDataKey(for: keyId))
        deleteCredentialKey(storedKeyPassphraseKey(for: keyId))

        // Update index
        var keys = getStoredSSHKeys()
        keys.removeAll { $0.id == keyId }
        try saveSSHKeysIndex(keys)

        logger.info("Deleted SSH key \(keyId.uuidString) from keychain library")
    }

    /// Update a stored SSH key's name
    func updateStoredSSHKeyName(_ keyId: UUID, name: String) throws {
        var keys = getStoredSSHKeys()
        guard let index = keys.firstIndex(where: { $0.id == keyId }) else {
            throw KeychainError.itemNotFound
        }
        keys[index].name = name
        try saveSSHKeysIndex(keys)
        logger.info("Updated SSH key name to '\(name)'")
    }

    private func storedKeyDataKey(for keyId: UUID) -> String {
        "sshkey.\(keyId.uuidString).data"
    }

    private func storedKeyPassphraseKey(for keyId: UUID) -> String {
        "sshkey.\(keyId.uuidString).passphrase"
    }
}

// KeychainError is defined in KeychainStore.swift
// ServerCredentials is defined in Server.swift
