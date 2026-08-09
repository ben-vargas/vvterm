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
    func apply(_ mutation: ServerMutation) async throws -> Server
}

@MainActor
protocol ServerCredentialStoring: AnyObject {
    func storeCredentials(_ credentials: ServerCredentials, for server: Server) throws
}

@MainActor
protocol ServerCredentialRepository: ServerCredentialStoring {
    func getCredentials(for server: Server) throws -> ServerCredentials
    func approveCredentialUse(for server: Server) throws
    func getStoredSSHKeys() -> [SSHKeyEntry]
    func getStoredSSHKeyData(for id: UUID) throws -> (key: Data, passphrase: String?)?
}

@MainActor
struct ServerSaveUseCase {
    private let mutations: any ServerMutationRepository
    private let credentials: any ServerCredentialStoring

    init(
        mutations: any ServerMutationRepository,
        credentials: any ServerCredentialStoring
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
        try credentials.storeCredentials(newCredentials, for: mutation.server)
        return try await mutations.apply(mutation)
    }
}
