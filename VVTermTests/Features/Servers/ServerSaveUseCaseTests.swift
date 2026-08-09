import Foundation
import Testing
@testable import VVTerm

@MainActor
struct ServerSaveUseCaseTests {
    @Test
    func createValidatesThenStoresCredentialsThenAppliesMutation() async throws {
        var events: [String] = []
        let repository = ServerMutationRepositoryFake(events: { events.append($0) })
        let credentialStore = ServerCredentialStoreFake(events: { events.append($0) })
        let useCase = ServerSaveUseCase(
            mutations: repository,
            credentials: credentialStore
        )
        let server = makeServer()
        var credentials = ServerCredentials(serverId: server.id)
        credentials.password = "secret"

        let saved = try await useCase.execute(
            .create(server),
            credentials: credentials,
            hasProAccess: true
        )

        #expect(saved == server)
        #expect(repository.validatedHasProAccess == true)
        #expect(credentialStore.storedServer == server)
        #expect(repository.appliedMutation == .create(server))
        #expect(events == ["validate", "credentials", "apply"])
    }

    @Test
    func validationFailureDoesNotStoreCredentialsOrApplyMutation() async {
        let repository = ServerMutationRepositoryFake()
        repository.validationError = TestFailure.rejected
        let credentialStore = ServerCredentialStoreFake()
        let useCase = ServerSaveUseCase(
            mutations: repository,
            credentials: credentialStore
        )
        let server = makeServer()

        await #expect(throws: TestFailure.self) {
            try await useCase.execute(
                .create(server),
                credentials: ServerCredentials(serverId: server.id),
                hasProAccess: false
            )
        }

        #expect(credentialStore.storedServer == nil)
        #expect(repository.appliedMutation == nil)
    }

    @Test
    func updateUsesExplicitUpdateMutation() async throws {
        let repository = ServerMutationRepositoryFake()
        let credentialStore = ServerCredentialStoreFake()
        let useCase = ServerSaveUseCase(
            mutations: repository,
            credentials: credentialStore
        )
        let server = makeServer()
        repository.currentServer = server

        _ = try await useCase.execute(
            .update(server),
            credentials: ServerCredentials(serverId: server.id),
            hasProAccess: false
        )

        #expect(repository.appliedMutation == .update(server))
    }

    @Test
    func createCredentialWriteFailureDoesNotApplyMetadataAndRemovesPartialCredentials() async {
        let repository = ServerMutationRepositoryFake()
        let credentialStore = ServerCredentialStoreFake()
        credentialStore.storeErrors = [TestFailure.credentialWrite]
        let useCase = ServerSaveUseCase(
            mutations: repository,
            credentials: credentialStore
        )
        let server = makeServer()

        await #expect(throws: TestFailure.self) {
            try await useCase.execute(
                .create(server),
                credentials: ServerCredentials(serverId: server.id),
                hasProAccess: true
            )
        }

        #expect(repository.appliedMutation == nil)
        #expect(credentialStore.deletedServerIDs == [server.id])
    }

    @Test
    func createMetadataFailureRemovesWrittenCredentials() async {
        let repository = ServerMutationRepositoryFake()
        repository.applyError = TestFailure.metadataApply
        let credentialStore = ServerCredentialStoreFake()
        let useCase = ServerSaveUseCase(
            mutations: repository,
            credentials: credentialStore
        )
        let server = makeServer()

        await #expect(throws: TestFailure.self) {
            try await useCase.execute(
                .create(server),
                credentials: ServerCredentials(serverId: server.id),
                hasProAccess: true
            )
        }

        #expect(credentialStore.storedServers == [server])
        #expect(credentialStore.deletedServerIDs == [server.id])
    }

    @Test
    func editMetadataFailureRestoresPreviousCredentialsAndEndpointBinding() async {
        let oldServer = makeServer(host: "old.example.com")
        var editedServer = oldServer
        editedServer.host = "new.example.com"

        let repository = ServerMutationRepositoryFake()
        repository.currentServer = oldServer
        repository.applyError = TestFailure.metadataApply
        let credentialStore = ServerCredentialStoreFake()
        var oldCredentials = ServerCredentials(serverId: oldServer.id)
        oldCredentials.password = "old-password"
        credentialStore.credentialsByServerID[oldServer.id] = oldCredentials
        let useCase = ServerSaveUseCase(
            mutations: repository,
            credentials: credentialStore
        )
        var newCredentials = ServerCredentials(serverId: editedServer.id)
        newCredentials.password = "new-password"

        await #expect(throws: TestFailure.self) {
            try await useCase.execute(
                .update(editedServer),
                credentials: newCredentials,
                hasProAccess: false
            )
        }

        #expect(credentialStore.storedServers == [editedServer, oldServer])
        #expect(credentialStore.storedPasswords == ["new-password", "old-password"])
        #expect(credentialStore.deletedServerIDs == [oldServer.id])
    }

    @Test
    func staleEditFailsBeforeCredentialSnapshotOrWrite() async {
        let repository = ServerMutationRepositoryFake()
        repository.validationError = VVTermError.serverNotFound
        let credentialStore = ServerCredentialStoreFake()
        let useCase = ServerSaveUseCase(
            mutations: repository,
            credentials: credentialStore
        )
        let server = makeServer()

        await #expect(throws: VVTermError.self) {
            try await useCase.execute(
                .update(server),
                credentials: ServerCredentials(serverId: server.id),
                hasProAccess: false
            )
        }

        #expect(credentialStore.requestedServers.isEmpty)
        #expect(credentialStore.storedServers.isEmpty)
    }

    @Test
    func rollbackFailureReturnsRetryableTransactionFailureWithoutApplyingMetadata() async {
        let repository = ServerMutationRepositoryFake()
        let credentialStore = ServerCredentialStoreFake()
        credentialStore.storeErrors = [TestFailure.credentialWrite]
        credentialStore.deleteError = TestFailure.rollback
        let useCase = ServerSaveUseCase(
            mutations: repository,
            credentials: credentialStore
        )
        let server = makeServer()

        await #expect(throws: ServerSaveTransactionError.self) {
            try await useCase.execute(
                .create(server),
                credentials: ServerCredentials(serverId: server.id),
                hasProAccess: true
            )
        }

        #expect(repository.appliedMutation == nil)
    }

    private func makeServer(host: String = "example.com") -> Server {
        Server(
            workspaceId: UUID(),
            name: "Server",
            host: host,
            username: "root"
        )
    }
}

@MainActor
private final class ServerMutationRepositoryFake: ServerMutationRepository {
    var validationError: Error?
    var applyError: Error?
    var validatedHasProAccess: Bool?
    var appliedMutation: ServerMutation?
    var currentServer: Server?

    private let events: (String) -> Void

    init(events: @escaping (String) -> Void = { _ in }) {
        self.events = events
    }

    func validate(_ mutation: ServerMutation, hasProAccess: Bool) throws {
        events("validate")
        validatedHasProAccess = hasProAccess
        if let validationError {
            throw validationError
        }
    }

    func apply(_ mutation: ServerMutation) async throws -> Server {
        events("apply")
        appliedMutation = mutation
        if let applyError {
            throw applyError
        }
        return mutation.server
    }

    func server(id: UUID) -> Server? {
        currentServer?.id == id ? currentServer : nil
    }
}

@MainActor
private final class ServerCredentialStoreFake: ServerCredentialTransactionRepository {
    var storedServer: Server?
    var storedServers: [Server] = []
    var storedPasswords: [String?] = []
    var requestedServers: [Server] = []
    var deletedServerIDs: [UUID] = []
    var credentialsByServerID: [UUID: ServerCredentials] = [:]
    var storeErrors: [Error] = []
    var deleteError: Error?

    private let events: (String) -> Void

    init(events: @escaping (String) -> Void = { _ in }) {
        self.events = events
    }

    func storeCredentials(_ credentials: ServerCredentials, for server: Server) throws {
        events("credentials")
        storedServer = server
        storedServers.append(server)
        storedPasswords.append(credentials.password)
        if !storeErrors.isEmpty {
            throw storeErrors.removeFirst()
        }
        credentialsByServerID[server.id] = credentials
    }

    func getCredentials(for server: Server) throws -> ServerCredentials {
        requestedServers.append(server)
        return credentialsByServerID[server.id] ?? ServerCredentials(serverId: server.id)
    }

    func deleteCredentials(for serverID: UUID) throws {
        deletedServerIDs.append(serverID)
        if let deleteError {
            throw deleteError
        }
        credentialsByServerID[serverID] = nil
    }
}

private enum TestFailure: Error {
    case rejected
    case credentialWrite
    case metadataApply
    case rollback
}
