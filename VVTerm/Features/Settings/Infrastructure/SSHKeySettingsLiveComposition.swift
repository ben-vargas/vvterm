import Foundation

@MainActor
private final class KeychainSSHKeySettingsRepository: SSHKeySettingsRepository {
    private let keychain: KeychainManager

    init(keychain: KeychainManager) {
        self.keychain = keychain
    }

    func loadKeys() -> [SSHKeyEntry] {
        keychain.getStoredSSHKeys()
    }

    func storeImportedKey(_ request: ImportedSSHKeyRequest) throws -> SSHKeyEntry {
        try keychain.storeSSHKeyEntry(
            name: request.name,
            privateKey: request.privateKey,
            passphrase: request.passphrase
        )
    }

    func generateAndStoreKey(_ request: GeneratedSSHKeyRequest) throws -> SSHKeyEntry {
        let key = try SSHKeyGenerator.generate(
            type: request.keyType,
            comment: request.comment
        )
        return try keychain.storeSSHKeyEntry(
            name: request.name,
            privateKey: key.privateKey,
            passphrase: request.passphrase,
            keyType: key.keyType,
            publicKey: key.publicKey
        )
    }

    func deleteKey(id: UUID) throws {
        try keychain.deleteStoredSSHKey(id)
    }
}

@MainActor
enum SSHKeySettingsLiveComposition {
    static func makeCoordinator(keychain: KeychainManager) -> SSHKeySettingsCoordinator {
        SSHKeySettingsCoordinator(
            repository: KeychainSSHKeySettingsRepository(keychain: keychain)
        )
    }
}

#if DEBUG
@MainActor
private final class PreviewSSHKeySettingsRepository: SSHKeySettingsRepository {
    func loadKeys() -> [SSHKeyEntry] { [] }

    func storeImportedKey(_ request: ImportedSSHKeyRequest) throws -> SSHKeyEntry {
        throw PreviewError.unsupported
    }

    func generateAndStoreKey(_ request: GeneratedSSHKeyRequest) throws -> SSHKeyEntry {
        throw PreviewError.unsupported
    }

    func deleteKey(id: UUID) throws {
        throw PreviewError.unsupported
    }

    private enum PreviewError: Error {
        case unsupported
    }
}

extension SSHKeySettingsCoordinator {
    static var preview: SSHKeySettingsCoordinator {
        SSHKeySettingsCoordinator(repository: PreviewSSHKeySettingsRepository())
    }
}
#endif
