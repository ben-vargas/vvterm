import Foundation

nonisolated enum ServerMutation: Equatable, Sendable {
    case create(Server)
    case update(Server)

    var server: Server {
        switch self {
        case .create(let server), .update(let server):
            return server
        }
    }
}

@MainActor
protocol ServerMutationRepository: AnyObject {
    func validate(_ mutation: ServerMutation, hasProAccess: Bool) throws
    func server(id: UUID) -> Server?
    func apply(_ mutation: ServerMutation) async throws -> Server
}

@MainActor
protocol ServerCredentialStoring: AnyObject {
    func storeCredentials(_ credentials: ServerCredentials, for server: Server) throws
}

@MainActor
protocol ServerCredentialTransactionRepository: ServerCredentialStoring {
    func getCredentials(for server: Server) throws -> ServerCredentials
    func deleteCredentials(for serverID: UUID) throws
}

@MainActor
protocol ServerCredentialRepository: ServerCredentialTransactionRepository {
    func getStoredSSHKeys() -> [SSHKeyEntry]
    func getStoredSSHKeyData(for id: UUID) throws -> (key: Data, passphrase: String?)?
}

@MainActor
struct ServerSaveUseCase {
    private let mutations: any ServerMutationRepository
    private let credentials: any ServerCredentialTransactionRepository

    init(
        mutations: any ServerMutationRepository,
        credentials: any ServerCredentialTransactionRepository
    ) {
        self.mutations = mutations
        self.credentials = credentials
    }

    func execute(
        _ mutation: ServerMutation,
        credentials newCredentials: ServerCredentials,
        hasProAccess: Bool
    ) async throws -> Server {
        try mutations.validate(mutation, hasProAccess: hasProAccess)
        let rollback = try credentialRollback(for: mutation)

        do {
            try credentials.storeCredentials(newCredentials, for: mutation.server)
            return try await mutations.apply(mutation)
        } catch {
            do {
                try rollbackCredentials(using: rollback)
            } catch let rollbackError {
                throw ServerSaveTransactionError(
                    originalError: error,
                    rollbackError: rollbackError
                )
            }
            throw error
        }
    }

    private func credentialRollback(for mutation: ServerMutation) throws -> CredentialRollback {
        switch mutation {
        case .create(let server):
            return .remove(server.id)
        case .update(let server):
            guard let existingServer = mutations.server(id: server.id) else {
                throw VVTermError.serverNotFound
            }
            return .restore(
                server: existingServer,
                credentials: try credentials.getCredentials(for: existingServer)
            )
        }
    }

    private func rollbackCredentials(using rollback: CredentialRollback) throws {
        switch rollback {
        case .remove(let serverID):
            try credentials.deleteCredentials(for: serverID)
        case .restore(let server, let previousCredentials):
            try credentials.deleteCredentials(for: server.id)
            try credentials.storeCredentials(previousCredentials, for: server)
        }
    }
}

private enum CredentialRollback {
    case remove(UUID)
    case restore(server: Server, credentials: ServerCredentials)
}

nonisolated struct ServerSaveTransactionError: Error, Equatable, Sendable {
    let originalErrorDescription: String
    let rollbackErrorDescription: String

    init(originalError: Error, rollbackError: Error) {
        originalErrorDescription = originalError.localizedDescription
        rollbackErrorDescription = rollbackError.localizedDescription
    }
}
