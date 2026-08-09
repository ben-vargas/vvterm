import Foundation
import Cloudflared

actor CloudflareTokenStoreAdapter: TokenStore {
    private let store: KeychainStore
    private let isSyncEnabled: @Sendable () -> Bool

    init(
        store: KeychainStore = KeychainStore(
            service: KeychainManager.cloudflareTokenService
        ),
        isSyncEnabled: @escaping @Sendable () -> Bool = { SyncSettings.isEnabled }
    ) {
        self.store = store
        self.isSyncEnabled = isSyncEnabled
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
        try store.setString(
            token,
            forKey: namespacedKey(for: key),
            scope: storageScope
        )
    }

    func removeToken(for key: String) async throws {
        try store.delete(namespacedKey(for: key), scope: storageScope)
    }

    private var storageScope: KeychainStorageScope {
        isSyncEnabled() ? .iCloud : .deviceOnly
    }

    private func namespacedKey(for key: String) -> String {
        "oauth.\(key)"
    }
}
