import Foundation
import Cloudflared

actor CloudflareTokenStoreAdapter: TokenStore {
    private let store: KeychainStore
    private let isSyncEnabled: @Sendable () -> Bool
    private let offlineChanges: CredentialOfflineChangeStore

    init(
        store: KeychainStore = KeychainStore(
            service: KeychainManager.cloudflareTokenService
        ),
        isSyncEnabled: @escaping @Sendable () -> Bool = { SyncSettings.isEnabled },
        offlineChanges: CredentialOfflineChangeStore = .shared
    ) {
        self.store = store
        self.isSyncEnabled = isSyncEnabled
        self.offlineChanges = offlineChanges
    }

    func readToken(for key: String) async throws -> String? {
        let key = namespacedKey(for: key)
        let preferredScope = storageScope
        if let token = try store.getString(key, scope: preferredScope) {
            return token
        }
        guard preferredScope == .iCloud else { return nil }
        return try store.getString(key, scope: .deviceOnly)
    }

    func writeToken(_ token: String, for key: String) async throws {
        let namespacedKey = namespacedKey(for: key)
        try store.setString(
            token,
            forKey: namespacedKey,
            scope: storageScope
        )
        if !isSyncEnabled() {
            try offlineChanges.record(.updated, for: .oauth(namespacedKey))
        }
    }

    func removeToken(for key: String) async throws {
        let namespacedKey = namespacedKey(for: key)
        if !isSyncEnabled() {
            try offlineChanges.record(.deleted, for: .oauth(namespacedKey))
        }
        for scope in KeychainStorageScope.allCases {
            try store.delete(namespacedKey, scope: scope)
        }
    }

    private var storageScope: KeychainStorageScope {
        isSyncEnabled() ? .iCloud : .deviceOnly
    }

    private func namespacedKey(for key: String) -> String {
        "oauth.\(key)"
    }
}
