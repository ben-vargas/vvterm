import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class SSHKeySettingsRepositorySpy: SSHKeySettingsRepository {
    var loadedKeys: [SSHKeyEntry] = []
    var importedRequests: [ImportedSSHKeyRequest] = []
    var generatedRequests: [GeneratedSSHKeyRequest] = []
    var deletedIDs: [UUID] = []
    var importError: Error?
    var generateError: Error?
    var deleteError: Error?

    func loadKeys() -> [SSHKeyEntry] {
        loadedKeys
    }

    func storeImportedKey(_ request: ImportedSSHKeyRequest) throws -> SSHKeyEntry {
        importedRequests.append(request)
        if let importError { throw importError }
        let entry = Self.entry(name: request.name)
        loadedKeys.append(entry)
        return entry
    }

    func generateAndStoreKey(_ request: GeneratedSSHKeyRequest) throws -> SSHKeyEntry {
        generatedRequests.append(request)
        if let generateError { throw generateError }
        let entry = Self.entry(name: request.name, keyType: request.keyType)
        loadedKeys.append(entry)
        return entry
    }

    func deleteKey(id: UUID) throws {
        deletedIDs.append(id)
        if let deleteError { throw deleteError }
        loadedKeys.removeAll { $0.id == id }
    }

    static func entry(
        id: UUID = UUID(),
        name: String,
        keyType: SSHKeyType? = nil
    ) -> SSHKeyEntry {
        SSHKeyEntry(
            id: id,
            name: name,
            hasPassphrase: false,
            createdAt: Date(timeIntervalSince1970: 42),
            keyType: keyType,
            publicKey: nil
        )
    }
}

@MainActor
struct SSHKeySettingsCoordinatorTests {
    private struct TestError: LocalizedError {
        var errorDescription: String? { "test failure" }
    }

    @Test
    func loadPublishesRepositoryKeys() {
        let repository = SSHKeySettingsRepositorySpy()
        repository.loadedKeys = [.init(
            id: UUID(),
            name: "Existing",
            hasPassphrase: true,
            createdAt: Date(timeIntervalSince1970: 1),
            keyType: .ed25519,
            publicKey: "ssh-ed25519 key"
        )]
        let coordinator = SSHKeySettingsCoordinator(repository: repository)

        coordinator.loadKeys()

        #expect(coordinator.keys == repository.loadedKeys)
    }

    @Test
    func importStoresExactRequestAndReloadsPublishedKeys() {
        let repository = SSHKeySettingsRepositorySpy()
        let coordinator = SSHKeySettingsCoordinator(repository: repository)
        let privateKey = Data("private".utf8)

        let entry = coordinator.storeImportedKey(
            name: "Imported",
            privateKey: privateKey,
            passphrase: "secret"
        )

        #expect(entry?.name == "Imported")
        #expect(repository.importedRequests == [ImportedSSHKeyRequest(
            name: "Imported",
            privateKey: privateKey,
            passphrase: "secret"
        )])
        #expect(coordinator.keys == repository.loadedKeys)
        #expect(coordinator.operationFailures.isEmpty)
    }

    @Test
    func generationPreservesCommentPolicyAndReloadsPublishedKeys() {
        let repository = SSHKeySettingsRepositorySpy()
        let coordinator = SSHKeySettingsCoordinator(repository: repository)

        let entry = coordinator.generateAndStoreKey(
            name: "Work Key",
            passphrase: nil,
            keyType: .rsa4096
        )

        #expect(entry?.keyType == .rsa4096)
        #expect(repository.generatedRequests == [GeneratedSSHKeyRequest(
            name: "Work Key",
            comment: "Work_Key",
            passphrase: nil,
            keyType: .rsa4096
        )])
        #expect(coordinator.keys == repository.loadedKeys)
    }

    @Test
    func deleteReloadsKeysAndPublishesClosedFailureOnError() {
        let repository = SSHKeySettingsRepositorySpy()
        let key = SSHKeySettingsRepositorySpy.entry(name: "Delete")
        repository.loadedKeys = [key]
        let coordinator = SSHKeySettingsCoordinator(repository: repository)
        coordinator.loadKeys()

        repository.deleteError = TestError()
        coordinator.deleteKey(key)
        #expect(coordinator.failureDetails(for: .deleteKey) == "test failure")
        #expect(coordinator.keys == [key])

        repository.deleteError = nil
        coordinator.deleteKey(key)
        #expect(coordinator.failureDetails(for: .deleteKey) == nil)
        #expect(coordinator.keys.isEmpty)
        #expect(repository.deletedIDs == [key.id, key.id])
    }

    @Test
    func importAndGenerationFailuresRemainDistinct() {
        let repository = SSHKeySettingsRepositorySpy()
        let coordinator = SSHKeySettingsCoordinator(repository: repository)
        repository.importError = TestError()

        #expect(coordinator.storeImportedKey(
            name: "Import",
            privateKey: Data(),
            passphrase: nil
        ) == nil)
        #expect(coordinator.failureDetails(for: .importKey) == "test failure")

        repository.generateError = TestError()
        #expect(coordinator.generateAndStoreKey(
            name: "Generate",
            passphrase: nil,
            keyType: .ed25519
        ) == nil)
        #expect(coordinator.failureDetails(for: .generateKey) == "test failure")
        #expect(coordinator.failureDetails(for: .importKey) == "test failure")
    }
}
