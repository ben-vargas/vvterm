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

        _ = try await useCase.execute(
            .update(server),
            credentials: ServerCredentials(serverId: server.id),
            hasProAccess: false
        )

        #expect(repository.appliedMutation == .update(server))
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Server",
            host: "example.com",
            username: "root"
        )
    }
}

@MainActor
private final class ServerMutationRepositoryFake: ServerMutationRepository {
    var validationError: Error?
    var validatedHasProAccess: Bool?
    var appliedMutation: ServerMutation?

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
        return mutation.server
    }
}

@MainActor
private final class ServerCredentialStoreFake: ServerCredentialStoring {
    var storedServer: Server?

    private let events: (String) -> Void

    init(events: @escaping (String) -> Void = { _ in }) {
        self.events = events
    }

    func storeCredentials(_ credentials: ServerCredentials, for server: Server) throws {
        events("credentials")
        storedServer = server
    }
}

private enum TestFailure: Error {
    case rejected
}
