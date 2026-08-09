import Foundation

typealias ServerStatsConnectionOperation = @Sendable (
    _ client: SSHClient
) async throws -> Void

typealias ServerStatsConnectionRunner = @Sendable (
    _ client: SSHClient,
    _ server: Server,
    _ credentials: ServerCredentials,
    _ disconnectWhenDone: Bool,
    _ operation: @escaping ServerStatsConnectionOperation
) async throws -> Void

@MainActor
struct ServerStatsCollectorDependencies {
    let makeClient: () -> SSHClient
    let loadCredentials: (Server) throws -> ServerCredentials
    let runWithConnection: ServerStatsConnectionRunner
    let makeAttemptID: () -> UUID
    let now: () -> Date
}
