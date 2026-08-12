import Foundation
import Testing
@testable import VVTerm

@MainActor
struct EnvironmentDeletionTransactionTests {
    @Test
    func planUpdatesWorkspaceServersSelectionAndSyncAsOneSnapshot() throws {
        let fixture = EnvironmentDeletionFixture()
        let plan = try fixture.makePlan()

        #expect(plan.updatedWorkspace.environments.map(\.id) == [ServerEnvironment.production.id])
        #expect(plan.updatedWorkspace.lastSelectedEnvironmentId == ServerEnvironment.production.id)
        #expect(plan.updatedServers.count == 1)
        #expect(plan.updatedServers[0].environment == .production)
        #expect(plan.resultingServers.first { $0.id == fixture.unaffectedServer.id } == fixture.unaffectedServer)
        #expect(plan.pendingMutations.count == 2)
    }

    @Test
    func planRejectsMissingOrBuiltInEnvironmentAndMissingFallback() {
        let fixture = EnvironmentDeletionFixture()

        #expect(throws: VVTermError.environmentNotFound) {
            try fixture.makePlan(environmentID: UUID())
        }
        #expect(throws: VVTermError.environmentDeletionNotAllowed) {
            try fixture.makePlan(environmentID: ServerEnvironment.production.id)
        }
        #expect(throws: VVTermError.environmentFallbackUnavailable) {
            try fixture.makePlan(fallbackID: UUID())
        }
    }

    @Test
    func queueFailureKeepsDurablePlanAndRestartCompletesIt() throws {
        let fixture = EnvironmentDeletionFixture()
        let plan = try fixture.makePlan()
        let store = EnvironmentDeletionStore()
        let failingQueue = EnvironmentDeletionQueue(shouldFail: true)
        let first = EnvironmentDeletionTransaction(store: store, mutationQueue: failingQueue)

        let failed = try first.commit(plan)

        #expect(failed.phase == .enqueueing)
        #expect(store.materializedPlan == plan)
        #expect(store.journal == failed)

        let recoveredQueue = EnvironmentDeletionQueue()
        let restarted = EnvironmentDeletionTransaction(store: store, mutationQueue: recoveredQueue)
        let recovered = try #require(try restarted.resumePending())

        #expect(recovered.phase == .complete)
        #expect(recoveredQueue.mutations == plan.pendingMutations)
        #expect(store.journal == nil)
    }

    @Test
    func localStoreLoadsJournalPlanAcrossRestart() throws {
        let fixture = EnvironmentDeletionFixture()
        let plan = try fixture.makePlan()
        let suiteName = "EnvironmentDeletionTransactionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ServerLocalStore(defaults: defaults)
        try store.storeEnvironmentDeletionJournal(EnvironmentDeletionJournal(plan: plan))

        let restarted = ServerLocalStore(defaults: defaults)
        guard case .loaded(let servers) = restarted.loadServers(),
              case .loaded(let workspaces) = restarted.loadWorkspaces() else {
            Issue.record("Expected the environment deletion plan after restart")
            return
        }

        #expect(servers == plan.resultingServers)
        #expect(workspaces == plan.resultingWorkspaces)
    }
}

@MainActor
private struct EnvironmentDeletionFixture {
    let custom = ServerEnvironment(name: "Review", shortName: "Rev", colorHex: "#123456")
    let workspace: Workspace
    let affectedServer: Server
    let unaffectedServer: Server

    init() {
        workspace = Workspace(
            name: "Workspace",
            environments: [.production, custom],
            lastSelectedEnvironmentId: custom.id
        )
        affectedServer = Server(
            workspaceId: workspace.id,
            environment: custom,
            name: "Affected",
            host: "affected.example.test",
            username: "root"
        )
        unaffectedServer = Server(
            workspaceId: workspace.id,
            environment: .production,
            name: "Unaffected",
            host: "unaffected.example.test",
            username: "root"
        )
    }

    func makePlan(
        environmentID: UUID? = nil,
        fallbackID: UUID = ServerEnvironment.production.id
    ) throws -> EnvironmentDeletionPlan {
        try EnvironmentDeletionPlan(
            workspaceID: workspace.id,
            environmentID: environmentID ?? custom.id,
            fallbackID: fallbackID,
            servers: [affectedServer, unaffectedServer],
            workspaces: [workspace],
            id: UUID(),
            mutationIDs: [UUID(), UUID()],
            mutationDate: Date(timeIntervalSinceReferenceDate: 100)
        )
    }
}

@MainActor
private final class EnvironmentDeletionStore: EnvironmentDeletionJournalStoring {
    var journal: EnvironmentDeletionJournal?
    var materializedPlan: EnvironmentDeletionPlan?

    func loadEnvironmentDeletionJournal() throws -> EnvironmentDeletionJournal? { journal }
    func storeEnvironmentDeletionJournal(_ journal: EnvironmentDeletionJournal) throws { self.journal = journal }
    func materializeEnvironmentDeletion(_ plan: EnvironmentDeletionPlan) throws { materializedPlan = plan }
    func clearEnvironmentDeletionJournal() throws { journal = nil }
}

@MainActor
private final class EnvironmentDeletionQueue: EnvironmentDeletionMutationEnqueuing {
    let shouldFail: Bool
    var mutations: [ServerPendingMutation] = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func enqueueEnvironmentDeletionMutations(_ mutations: [ServerPendingMutation]) throws {
        if shouldFail { throw EnvironmentDeletionTestError.queue }
        self.mutations = mutations
    }
}

private enum EnvironmentDeletionTestError: Error {
    case queue
}
