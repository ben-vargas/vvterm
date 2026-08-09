import Foundation
import Security
import os.log

// MARK: - Keychain Manager

@MainActor
final class KeychainManager {
    static let shared = KeychainManager()

    private let store: KeychainStore
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Keychain")

    private init() {
        store = KeychainStore(service: "app.vivy.vvterm")
    }

    // MARK: - Password Operations

    private func storePassword(for serverId: UUID, password: String) throws {
        let key = passwordKey(for: serverId)
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try store.set(data, forKey: key)
        logger.info("Stored password for server \(serverId.uuidString)")
    }

    private func getPassword(for serverId: UUID) throws -> String? {
        let key = passwordKey(for: serverId)

        // Try store first
        if let data = try store.get(key) {
            guard let password = String(data: data, encoding: .utf8) else {
                throw KeychainError.decodingFailed
            }
            return password
        }

        return nil
    }

    // MARK: - SSH Key Operations

    private func storeSSHKey(for serverId: UUID, privateKey: Data, passphrase: String?, publicKey: Data? = nil) throws {
        let keyKey = sshKeyKey(for: serverId)
        try store.set(privateKey, forKey: keyKey)

        if let passphrase = passphrase {
            let passphraseKey = sshPassphraseKey(for: serverId)
            guard let passphraseData = passphrase.data(using: .utf8) else {
                throw KeychainError.encodingFailed
            }
            try store.set(passphraseData, forKey: passphraseKey)
        }

        let publicKeyKey = sshPublicKeyKey(for: serverId)
        if let publicKey, !publicKey.isEmpty {
            try store.set(publicKey, forKey: publicKeyKey)
        } else {
            try? store.delete(publicKeyKey)
        }

        logger.info("Stored SSH key for server \(serverId.uuidString)")
    }

    private func getSSHKey(for serverId: UUID) throws -> (key: Data, passphrase: String?, publicKey: Data?)? {
        let keyKey = sshKeyKey(for: serverId)
        let passphraseKey = sshPassphraseKey(for: serverId)
        let publicKeyKey = sshPublicKeyKey(for: serverId)

        // Try store first
        if let keyData = try store.get(keyKey) {
            var passphrase: String? = nil
            if let passphraseData = try store.get(passphraseKey) {
                passphrase = String(data: passphraseData, encoding: .utf8)
            }
            let publicKeyData = try store.get(publicKeyKey)
            return (key: keyData, passphrase: passphrase, publicKey: publicKeyData)
        }

        return nil
    }

    // MARK: - Full Credentials

    func getCredentials(for server: Server) throws -> ServerCredentials {
        var credentials = ServerCredentials(serverId: server.id)

        logger.info("Getting credentials for server \(server.id.uuidString), authMethod: \(String(describing: server.authMethod))")

        if server.connectionMode == .tailscale {
            logger.info("Server \(server.id.uuidString) uses tailscale mode; skipping keychain credential lookup")
            return credentials
        }

        guard try credentialBindingStatus(for: server) != .approvalRequired else {
            logger.warning("Blocked credentials for a changed server endpoint: \(server.id.uuidString)")
            throw ServerCredentialAccessError.approvalRequired
        }

        switch server.authMethod {
        case .password:
            credentials.password = try getPassword(for: server.id)
            logger.info("Password retrieved: \(credentials.password != nil)")
        case .sshKey:
            if let sshData = try getSSHKey(for: server.id) {
                credentials.privateKey = sshData.key
                credentials.publicKey = sshData.publicKey
            }
        case .sshKeyWithPassphrase:
            if let sshData = try getSSHKey(for: server.id) {
                credentials.privateKey = sshData.key
                credentials.passphrase = sshData.passphrase
                credentials.publicKey = sshData.publicKey
            }
        }

        if server.connectionMode == .cloudflare, server.cloudflareAccessMode == .serviceToken,
           let cloudflareToken = try getCloudflareServiceToken(for: server.id) {
            credentials.cloudflareClientID = cloudflareToken.clientID
            credentials.cloudflareClientSecret = cloudflareToken.clientSecret
        }

        return credentials
    }

    func storeCredentials(_ credentials: ServerCredentials, for server: Server) throws {
        guard credentials.serverId == server.id else {
            throw KeychainError.credentialServerMismatch
        }

        if server.connectionMode != .tailscale {
            switch server.authMethod {
            case .password:
                if let password = credentials.password {
                    try storePassword(for: server.id, password: password)
                }
            case .sshKey, .sshKeyWithPassphrase:
                if let privateKey = credentials.privateKey {
                    try storeSSHKey(
                        for: server.id,
                        privateKey: privateKey,
                        passphrase: credentials.passphrase,
                        publicKey: credentials.publicKey
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
                clientSecret: clientSecret
            )
        } else {
            deleteCloudflareServiceToken(for: server.id)
        }

        try approveCredentialUse(for: server)
    }

    func credentialBindingStatus(for server: Server) throws -> ServerCredentialBindingStatus {
        let hasCredentials = try credentialKeys(for: server.id).contains { key in
            try store.contains(key)
        }
        guard hasCredentials else { return .noCredentials }

        let storedBinding: ServerCredentialBinding?
        if let data = try store.get(credentialBindingKey(for: server.id)) {
            storedBinding = try? JSONDecoder().decode(ServerCredentialBinding.self, from: data)
        } else {
            storedBinding = nil
        }

        return ServerCredentialBindingStatus.resolve(
            storedBinding: storedBinding,
            currentBinding: ServerCredentialBinding(server: server),
            hasStoredCredentials: true
        )
    }

    func approveCredentialUse(for server: Server) throws {
        let hasCredentials = try credentialKeys(for: server.id).contains { key in
            try store.contains(key)
        }
        guard hasCredentials else {
            try? store.delete(credentialBindingKey(for: server.id))
            return
        }

        let binding = ServerCredentialBinding(server: server)
        let data = try JSONEncoder().encode(binding)
        try store.set(data, forKey: credentialBindingKey(for: server.id))
        logger.info("Approved credential endpoint for server \(server.id.uuidString)")
    }

    // MARK: - Cloudflare Service Token

    private func storeCloudflareServiceToken(for serverId: UUID, clientID: String, clientSecret: String) throws {
        let idKey = cloudflareClientIDKey(for: serverId)
        let secretKey = cloudflareClientSecretKey(for: serverId)

        guard let idData = clientID.data(using: .utf8),
              let secretData = clientSecret.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        try store.set(idData, forKey: idKey)
        try store.set(secretData, forKey: secretKey)
        logger.info("Stored Cloudflare service token for server \(serverId.uuidString)")
    }

    private func getCloudflareServiceToken(for serverId: UUID) throws -> (clientID: String, clientSecret: String)? {
        let idKey = cloudflareClientIDKey(for: serverId)
        let secretKey = cloudflareClientSecretKey(for: serverId)

        guard let idData = try store.get(idKey),
              let secretData = try store.get(secretKey),
              let clientID = String(data: idData, encoding: .utf8),
              let clientSecret = String(data: secretData, encoding: .utf8) else {
            return nil
        }

        return (clientID: clientID, clientSecret: clientSecret)
    }

    private func deleteCloudflareServiceToken(for serverId: UUID) {
        try? store.delete(cloudflareClientIDKey(for: serverId))
        try? store.delete(cloudflareClientSecretKey(for: serverId))
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

        try? store.delete(passwordKey)
        try? store.delete(keyKey)
        try? store.delete(passphraseKey)
        try? store.delete(publicKeyKey)
        try? store.delete(cloudflareIDKey)
        try? store.delete(cloudflareSecretKey)
        try? store.delete(bindingKey)

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

    // MARK: - Reusable SSH Keys (Keychain Library)

    private let sshKeysIndexKey = "vvterm.sshkeys.index"

    /// Get all stored SSH key entries (metadata only, not the actual keys)
    func getStoredSSHKeys() -> [SSHKeyEntry] {
        guard let data = try? store.get(sshKeysIndexKey),
              let keys = try? JSONDecoder().decode([SSHKeyEntry].self, from: data) else {
            return []
        }
        return keys.sorted { $0.createdAt > $1.createdAt }
    }

    /// Save the SSH key index
    private func saveSSHKeysIndex(_ keys: [SSHKeyEntry]) throws {
        let data = try JSONEncoder().encode(keys)
        try store.set(data, forKey: sshKeysIndexKey)
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
        try store.set(privateKey, forKey: storedKeyDataKey(for: entry.id))

        // Store passphrase if provided
        if let passphrase = passphrase, !passphrase.isEmpty,
           let passphraseData = passphrase.data(using: .utf8) {
            try store.set(passphraseData, forKey: storedKeyPassphraseKey(for: entry.id))
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
        guard let keyData = try store.get(storedKeyDataKey(for: keyId)) else {
            return nil
        }

        var passphrase: String? = nil
        if let passphraseData = try store.get(storedKeyPassphraseKey(for: keyId)) {
            passphrase = String(data: passphraseData, encoding: .utf8)
        }

        return (key: keyData, passphrase: passphrase)
    }

    /// Delete a stored SSH key from the library
    func deleteStoredSSHKey(_ keyId: UUID) throws {
        // Delete key data
        try? store.delete(storedKeyDataKey(for: keyId))
        try? store.delete(storedKeyPassphraseKey(for: keyId))

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
