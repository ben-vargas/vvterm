import Foundation
import Testing
@testable import VVTerm

@MainActor
struct ServerStateStoreTests {
    @Test
    func twoStoresKeepMutationAndPersistenceIsolated() throws {
        let firstWorkspace = makeWorkspace(id: "10000000-0000-0000-0000-000000000001")
        let secondWorkspace = makeWorkspace(id: "10000000-0000-0000-0000-000000000002")
        let firstRepository = ServerStateLocalRepository(
            servers: [],
            workspaces: [firstWorkspace]
        )
        let secondRepository = ServerStateLocalRepository(
            servers: [],
            workspaces: [secondWorkspace]
        )
        let firstStore = makeStore(repository: firstRepository)
        let secondStore = makeStore(repository: secondRepository)
        let server = makeServer(workspaceID: firstWorkspace.id)

        _ = try firstStore.commitMutation(
            .insertServer(server),
            now: Date(timeIntervalSinceReferenceDate: 2_000)
        )

        #expect(firstStore.servers.map(\.id) == [server.id])
        #expect(firstRepository.servers.map(\.id) == [server.id])
        #expect(secondStore.servers.isEmpty)
        #expect(secondRepository.servers.isEmpty)
        #expect(firstStore.snapshot != secondStore.snapshot)
    }

    @Test
    func failedPersistenceDoesNotPublishPlannedMutation() {
        let workspace = makeWorkspace(id: "10000000-0000-0000-0000-000000000003")
        let repository = ServerStateLocalRepository(servers: [], workspaces: [workspace])
        repository.persistError = ServerStateStoreTestError.persistence
        let store = makeStore(repository: repository)
        let originalSnapshot = store.snapshot

        #expect(throws: ServerStateStoreTestError.self) {
            _ = try store.commitMutation(
                .insertServer(makeServer(workspaceID: workspace.id)),
                now: Date(timeIntervalSinceReferenceDate: 2_000)
            )
        }

        #expect(store.snapshot == originalSnapshot)
        #expect(repository.persistAttempts == 1)
    }

    @Test
    func unreadableLocalCollectionIssueBelongsToItsStoreAndCanBeDismissed() {
        let issue = ServerLocalStorageIssue(
            collection: .servers,
            quarantineKey: "servers.quarantine"
        )
        let unreadableRepository = ServerStateLocalRepository(
            serverLoadResult: .unreadable(issue),
            workspaceLoadResult: .missing
        )
        let healthyRepository = ServerStateLocalRepository(servers: [], workspaces: [])
        let unreadableStore = makeStore(repository: unreadableRepository)
        let healthyStore = makeStore(repository: healthyRepository)

        #expect(unreadableStore.localStorageIssues == [issue])
        #expect(healthyStore.localStorageIssues.isEmpty)

        unreadableStore.dismissLocalStorageIssues()

        #expect(unreadableStore.localStorageIssues.isEmpty)
        #expect(healthyStore.localStorageIssues.isEmpty)
    }

    private func makeStore(repository: ServerStateLocalRepository) -> ServerStateStore {
        ServerStateStore(
            dependencies: ServerStateStoreDependencies(
                localRepository: repository,
                preferences: ServerStatePreferences(),
                freePlanTracker: ServerStateFreePlanTracker(),
                isSyncEnabled: { false },
                now: { Date(timeIntervalSinceReferenceDate: 1_000) },
                makeID: { UUID(uuidString: "90000000-0000-0000-0000-000000000001")! },
                defaultWorkspaceName: { "My Servers" },
                canonicalDefaultWorkspaceNames: { ["My Servers"] }
            )
        )
    }

    private func makeWorkspace(id: String) -> Workspace {
        Workspace(
            id: UUID(uuidString: id)!,
            name: "Workspace",
            order: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func makeServer(workspaceID: UUID) -> Server {
        Server(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            workspaceId: workspaceID,
            name: "Server",
            host: "server.example.test",
            username: "root",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }
}

@MainActor
private final class ServerStateLocalRepository: ServerLocalRepository {
    var servers: [Server]
    var workspaces: [Workspace]
    var persistError: Error?
    var persistAttempts = 0
    var journal: WorkspaceDeletionJournal?

    private let serverLoadResult: ServerLocalLoadResult<[Server]>?
    private let workspaceLoadResult: ServerLocalLoadResult<[Workspace]>?

    init(servers: [Server], workspaces: [Workspace]) {
        self.servers = servers
        self.workspaces = workspaces
        serverLoadResult = nil
        workspaceLoadResult = nil
    }

    init(
        serverLoadResult: ServerLocalLoadResult<[Server]>,
        workspaceLoadResult: ServerLocalLoadResult<[Workspace]>
    ) {
        servers = []
        workspaces = []
        self.serverLoadResult = serverLoadResult
        self.workspaceLoadResult = workspaceLoadResult
    }

    func loadSnapshot() -> ServerLocalRepositorySnapshot {
        ServerLocalRepositorySnapshot(
            servers: serverLoadResult ?? .loaded(servers),
            workspaces: workspaceLoadResult ?? .loaded(workspaces)
        )
    }

    func persist(servers: [Server], workspaces: [Workspace]) throws {
        persistAttempts += 1
        if let persistError { throw persistError }
        self.servers = servers
        self.workspaces = workspaces
    }

    func clearServerData() {
        servers = []
        workspaces = []
    }

    func loadWorkspaceDeletionJournal() throws -> WorkspaceDeletionJournal? { journal }
    func storeWorkspaceDeletionJournal(_ journal: WorkspaceDeletionJournal) throws {
        self.journal = journal
    }
    func materializeWorkspaceDeletion(_ plan: WorkspaceDeletionPlan) throws {
        servers = plan.remainingServers
        workspaces = plan.remainingWorkspaces
    }
    func clearWorkspaceDeletionJournal() throws { journal = nil }
}

@MainActor
private final class ServerStatePreferences: ServerManagerPreferences {
    var didBootstrapDefaultWorkspace = true
    var hasSeenWelcome = true
    var freePlanGeneration: FreePlanGeneration? = .currentOneServer
    var pendingBootstrapWorkspaceID: UUID?
}

@MainActor
private final class ServerStateFreePlanTracker: FreePlanAssignmentTracking {
    func trackFreePlanGenerationAssigned(
        generation: String,
        serverCount: Int,
        reason: String
    ) {}
}

private enum ServerStateStoreTestError: Error {
    case persistence
}
