import Foundation

nonisolated struct ServerStatsConnectionIdentity: Hashable, Sendable {
    private let value: ObjectIdentifier

    init(_ value: AnyObject) {
        self.value = ObjectIdentifier(value)
    }
}

nonisolated enum ServerStatsClientOwnership: Equatable, Sendable {
    case owned
    case shared

    var disconnectWhenDone: Bool { self == .owned }
}

nonisolated struct ServerStatsApprovalRequest: Identifiable, Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        case credentialEndpoint
        case hostKey
    }

    let id: String
    let serverID: UUID
    let kind: Kind
}

@MainActor
protocol ServerStatsCollectionTarget {
    var serverID: UUID { get }
}

@MainActor
protocol ServerStatsConnectionReference {
    var identity: ServerStatsConnectionIdentity { get }
}

@MainActor
protocol ServerStatsApprovalReference: AnyObject, Sendable {
    var request: ServerStatsApprovalRequest { get }
}

struct ServerStatsApprovalRequired: Error {
    let reference: any ServerStatsApprovalReference
}

nonisolated struct ServerStatsCollectionPreparation: Sendable {
    let platformName: String
    let profile: HardwareProfile?
}

@MainActor
protocol ServerStatsCollectionSession: AnyObject {
    var connectionIdentity: ServerStatsConnectionIdentity { get }
    var ownership: ServerStatsClientOwnership { get }

    func runCollection(
        _ operation: @MainActor @escaping () async throws -> Void
    ) async throws
    func disconnect() async
    func prepareIfNeeded() async -> ServerStatsCollectionPreparation?
    func collectStats(collectDocker: Bool) async throws -> ServerStats
    func terminateProcess(_ process: ProcessInfo) async throws
    func loadProcesses(fallback: [ProcessInfo]) async throws -> [ProcessInfo]
    func loadDockerStats(fallback: DockerStats) async -> DockerStats
    func loadStorageHealth(for volume: VolumeInfo) async throws -> StorageHealthResult
    func performDockerAction(
        _ action: DockerContainerAction,
        on container: DockerContainer,
        fallback: DockerStats
    ) async throws -> DockerStats
}

@MainActor
struct ServerStatsCollectorDependencies {
    let makeOwnedConnection: () -> any ServerStatsConnectionReference
    let makeSession: (
        _ target: any ServerStatsCollectionTarget,
        _ connection: any ServerStatsConnectionReference,
        _ ownership: ServerStatsClientOwnership
    ) throws -> any ServerStatsCollectionSession
    let makeAttemptID: () -> UUID
}
