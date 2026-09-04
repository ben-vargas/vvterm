import Foundation
import Combine
import os.log

@MainActor
struct ServerStateStoreDependencies {
    let localRepository: any ServerLocalRepository
    let preferences: any ServerManagerPreferences
    let freePlanTracker: any FreePlanAssignmentTracking
    let isSyncEnabled: () -> Bool
    let now: () -> Date
    let makeID: () -> UUID
    let defaultWorkspaceName: () -> String
}

nonisolated enum ServerStateStoreError: Error, Equatable, Sendable {
    case proAccessRequiredForCustomEnvironment
}

@MainActor
final class ServerStateStore: ObservableObject {
    @Published private(set) var snapshot: ServerManagerSnapshot

    private let dependencies: ServerStateStoreDependencies
    private let mutationCommands = ServerMutationCommandRepository()
    private let logger = Logger(
        subsystem: "app.vivy.VVTerm",
        category: "ServerStateStore"
    )
    private(set) var initialWorkspaceBootstrapState = InitialWorkspaceBootstrapState.inactive

    init(dependencies: ServerStateStoreDependencies) {
        self.dependencies = dependencies
        snapshot = ServerManagerSnapshot(
            freePlanGeneration: dependencies.preferences.freePlanGeneration ?? .currentOneServer
        )
        loadLocalData()
        refreshFreePlanGeneration(
            persistCurrentIfNeeded: !isSyncEnabled,
            reason: "local_load"
        )
    }

    var servers: [Server] { snapshot.servers }
    var workspaces: [Workspace] { snapshot.workspaces }
    var loadState: ServerDataLoadState { snapshot.loadState }
    var localStorageIssues: [ServerLocalStorageIssue] { snapshot.localStorageIssues }
    var ambiguousCloudRecovery: AmbiguousCloudRecoveryState? {
        snapshot.ambiguousCloudRecovery
    }
    var freePlanGeneration: FreePlanGeneration { snapshot.freePlanGeneration }
    var isLoading: Bool { loadState.isLoading }
    var error: String? { loadState.errorMessage }
    var isSyncEnabled: Bool { dependencies.isSyncEnabled() }
    var shouldForceRemoteFullFetchForBootstrap: Bool {
        initialWorkspaceBootstrapState == .awaitingAuthoritativeRemoteState
    }

    var hasPendingServerDataMutation: Bool {
        (try? dependencies.localRepository.loadServerDataMutationJournal()) != nil
    }

    var localCacheContainsUserData: Bool {
        !servers.isEmpty || !workspaces.isEmpty
    }

    private var hasResolvedInitialWorkspace: Bool {
        get { dependencies.preferences.hasResolvedInitialWorkspace }
        set { dependencies.preferences.hasResolvedInitialWorkspace = newValue }
    }

    private var hasSeenWelcome: Bool {
        dependencies.preferences.hasSeenWelcome
    }

    func startLoading(operationID: UUID) -> UUID {
        updateSnapshot { snapshot in
            _ = snapshot.loadState.start(operationID: operationID)
        }
        return operationID
    }

    @discardableResult
    func finishLoading(operationID: UUID) -> Bool {
        var didFinish = false
        updateSnapshot { snapshot in
            didFinish = snapshot.loadState.finish(operationID: operationID)
        }
        return didFinish
    }

    @discardableResult
    func failLoading(operationID: UUID, message: String) -> Bool {
        var didFail = false
        updateSnapshot { snapshot in
            didFail = snapshot.loadState.fail(operationID: operationID, message: message)
        }
        return didFail
    }

    func resetLoading() {
        updateSnapshot { $0.loadState.reset() }
    }

    func dismissLocalStorageIssues() {
        updateSnapshot { $0.localStorageIssues.removeAll() }
    }

    func automaticFullFetchNeedsRecovery(
        _ changes: ServerRemoteChanges,
        pendingMutations: [ServerPendingMutation]
    ) -> Bool {
        guard changes.isFullFetch, localCacheContainsUserData else {
            return false
        }

        let cloudServerIDs = Set(changes.servers.map(\.id))
        let cloudWorkspaceIDs = Set(changes.workspaces.map(\.id))
        let deletedServerIDs = Set(changes.deletedServerIDs)
        let deletedWorkspaceIDs = Set(changes.deletedWorkspaceIDs)
        var explainedServerIDs = cloudServerIDs.union(deletedServerIDs)
        var explainedWorkspaceIDs = cloudWorkspaceIDs.union(deletedWorkspaceIDs)
        if initialWorkspaceBootstrapState == .awaitingAuthoritativeRemoteState {
            explainedWorkspaceIDs.insert(InitialWorkspaceBootstrapState.workspaceID)
        }

        for mutation in pendingMutations {
            switch mutation.payload {
            case .serverUpsert(let server), .serverDelete(let server):
                explainedServerIDs.insert(server.id)
            case .initialWorkspaceCreate(let workspace),
                 .workspaceUpsert(let workspace),
                 .workspaceDelete(let workspace):
                explainedWorkspaceIDs.insert(workspace.id)
            }
        }

        let hasUnexplainedServer = servers.contains { server in
            !explainedServerIDs.contains(server.id)
                && !deletedWorkspaceIDs.contains(server.workspaceId)
        }
        let hasUnexplainedWorkspace = workspaces.contains {
            !explainedWorkspaceIDs.contains($0.id)
        }
        return hasUnexplainedServer || hasUnexplainedWorkspace
    }

    func preserveAmbiguousCloudRecoveryBackup() throws {
        let backup = AmbiguousCloudRecoveryBackup(
            servers: servers,
            workspaces: workspaces
        )
        try dependencies.localRepository.storeAmbiguousCloudRecoveryBackup(backup)
        let storedBackup = try dependencies.localRepository.loadAmbiguousCloudRecoveryBackup()
        guard storedBackup != nil else { throw ServerLocalStoreError.persistenceFailed }
        updateSnapshot { $0.ambiguousCloudRecovery = .decisionRequired }
    }

    func clearAmbiguousCloudRecovery() throws {
        try dependencies.localRepository.clearAmbiguousCloudRecoveryBackup()
        updateSnapshot { $0.ambiguousCloudRecovery = nil }
    }

    func persistCurrentCollections() {
        do {
            try persistCurrentCollectionsForRemoteAcceptance()
        } catch {
            logger.error("Failed to persist local server data: \(error.localizedDescription)")
        }
    }

    func persistCurrentCollectionsForRemoteAcceptance() throws {
        try dependencies.localRepository.persist(
            servers: servers,
            workspaces: workspaces
        )
    }

    func restorePersistedCollections() {
        applyPersistedCollections(dependencies.localRepository.loadSnapshot())
    }

    func clearLocalDataAndState() throws {
        try dependencies.localRepository.clearServerData()
        var nextSnapshot = snapshot
        nextSnapshot.servers = []
        nextSnapshot.workspaces = []
        nextSnapshot.loadState.reset()
        snapshot = nextSnapshot
    }

    func commitMutation(
        _ command: ServerMutationCommand,
        now: Date
    ) throws -> ServerMutationCommandResult {
        let result = try mutationCommands.execute(
            command,
            servers: servers,
            workspaces: workspaces,
            now: now
        )
        try dependencies.localRepository.persist(
            servers: result.servers,
            workspaces: result.workspaces
        )
        applyMutationResult(result)
        return result
    }

    func planMutation(
        _ command: ServerMutationCommand,
        now: Date
    ) throws -> ServerMutationCommandResult {
        try mutationCommands.execute(
            command,
            servers: servers,
            workspaces: workspaces,
            now: now
        )
    }

    func applyMutationResult(_ result: ServerMutationCommandResult) {
        replaceCollections(servers: result.servers, workspaces: result.workspaces)
    }

    func makeServerDataMutationTransaction(
        mutationQueue: any ServerDataMutationEnqueuing,
        credentials: any ServerMutationCredentialTransacting
    ) -> ServerDataMutationTransaction {
        ServerDataMutationTransaction(
            store: dependencies.localRepository,
            mutationQueue: mutationQueue,
            credentials: credentials
        )
    }

    func applyCommittedServerDataMutation(_ plan: ServerDataMutationPlan) {
        replaceCollections(
            servers: plan.resultingServers,
            workspaces: plan.resultingWorkspaces
        )
    }

    func replaceCollections(servers: [Server], workspaces: [Workspace]) {
        updateSnapshot { snapshot in
            snapshot.servers = servers
            snapshot.workspaces = workspaces
        }
    }

    func applyPendingSyncOverlay(_ mutations: [ServerPendingMutation]) {
        var updatedServers = servers
        var updatedWorkspaces = workspaces

        for mutation in mutations {
            let workspace: Workspace
            switch mutation.payload {
            case .initialWorkspaceCreate(let candidate), .workspaceUpsert(let candidate):
                workspace = candidate
            case .serverUpsert, .serverDelete, .workspaceDelete:
                continue
            }
            if let index = updatedWorkspaces.firstIndex(where: { $0.id == workspace.id }) {
                updatedWorkspaces[index] = workspace
            } else {
                updatedWorkspaces.append(workspace)
            }
        }

        for mutation in mutations {
            guard case .serverUpsert(let server) = mutation.payload else { continue }
            if let index = updatedServers.firstIndex(where: { $0.id == server.id }) {
                updatedServers[index] = server
            } else {
                updatedServers.append(server)
            }
        }

        for mutation in mutations {
            guard case .serverDelete(let server) = mutation.payload else { continue }
            updatedServers.removeAll { $0.id == server.id }
        }

        for mutation in mutations {
            guard case .workspaceDelete(let workspace) = mutation.payload else { continue }
            updatedWorkspaces.removeAll { $0.id == workspace.id }
            updatedServers.removeAll { $0.workspaceId == workspace.id }
        }

        replaceCollections(servers: updatedServers, workspaces: updatedWorkspaces)
    }

    @discardableResult
    func replaceWorkspaceIfUnchanged(
        _ expected: Workspace,
        with replacement: Workspace
    ) -> Bool {
        guard expected.id == replacement.id,
              let index = workspaces.firstIndex(where: { $0.id == expected.id }),
              workspaces[index] == expected else {
            return false
        }
        updateSnapshot { $0.workspaces[index] = replacement }
        return true
    }

    func applyRemoteChanges(
        _ changes: ServerRemoteChanges,
        canReplaceLocalState: Bool = true
    ) {
        if changes.isFullFetch && canReplaceLocalState {
            replaceCollections(
                servers: dedupedServers(from: changes.servers),
                workspaces: dedupedWorkspaces(from: changes.workspaces)
            )
            return
        }

        var workspaceMap = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        for workspace in changes.workspaces {
            workspaceMap[workspace.id] = workspace
        }
        for workspaceID in changes.deletedWorkspaceIDs {
            workspaceMap[workspaceID] = nil
        }

        var serverMap = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        for server in changes.servers {
            serverMap[server.id] = server
        }
        for serverID in changes.deletedServerIDs {
            serverMap[serverID] = nil
        }

        replaceCollections(
            servers: Array(serverMap.values).sorted { $0.name < $1.name },
            workspaces: Array(workspaceMap.values).sorted { $0.order < $1.order }
        )
    }

    func repairOrphanedServers(at date: Date) -> (workspace: Workspace?, servers: [Server]) {
        let originalWorkspaceIDs = Set(workspaces.map(\.id))
        let orphanedServers = servers.filter { !originalWorkspaceIDs.contains($0.workspaceId) }
        guard !orphanedServers.isEmpty else { return (nil, []) }

        var updatedWorkspaces = workspaces
        var repairWorkspace: Workspace?
        if updatedWorkspaces.isEmpty {
            let fallbackWorkspace = makeDefaultWorkspace(id: dependencies.makeID())
            repairWorkspace = Self.workspaceForOrphanRepair(
                existingWorkspaces: updatedWorkspaces,
                servers: servers,
                fallbackWorkspace: fallbackWorkspace
            )
            if let repairWorkspace {
                updatedWorkspaces = [repairWorkspace]
            }
        }

        guard let destination = updatedWorkspaces.first else { return (nil, []) }
        var repairedServers: [Server] = []
        let updatedServers = servers.map { server -> Server in
            guard !originalWorkspaceIDs.contains(server.workspaceId) else { return server }
            var repaired = server
            repaired.workspaceId = destination.id
            repaired.updatedAt = date
            repairedServers.append(repaired)
            return repaired
        }
        replaceCollections(servers: updatedServers, workspaces: updatedWorkspaces)
        return (repairWorkspace, repairedServers)
    }

    func updateLastConnected(for serverID: UUID, at date: Date) throws {
        try requireNoPendingServerDataMutation()
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        updateSnapshot { $0.servers[index].lastConnected = date }
        persistCurrentCollections()
    }

    func planWorkspaceReorder(
        from source: IndexSet,
        to destination: Int,
        at date: Date
    ) throws -> [Workspace] {
        try requireNoPendingServerDataMutation()
        var reordered = workspaces
        reordered.moveElements(fromOffsets: source, toOffset: destination)
        for index in reordered.indices {
            var workspace = reordered[index]
            workspace.order = index
            workspace.updatedAt = date
            reordered[index] = workspace
        }
        return reordered
    }

    func refreshFreePlanGeneration(persistCurrentIfNeeded: Bool, reason: String) {
        if let storedGeneration = dependencies.preferences.freePlanGeneration {
            updateSnapshot { $0.freePlanGeneration = storedGeneration }
            return
        }

        if servers.contains(where: { $0.createdAt < FreeTierLimits.currentOneServerPlanCutoff }) {
            persistFreePlanGeneration(.legacyThreeServers, reason: reason)
        } else if persistCurrentIfNeeded {
            persistFreePlanGeneration(.currentOneServer, reason: reason)
        } else {
            updateSnapshot { $0.freePlanGeneration = .currentOneServer }
        }
    }

    func initialWorkspaceAfterAuthoritativeEmptyRemoteState(
        _ changes: ServerRemoteChanges
    ) -> Workspace? {
        guard initialWorkspaceBootstrapState == .awaitingAuthoritativeRemoteState,
              changes.isFullFetch,
              changes.workspaces.isEmpty,
              changes.servers.isEmpty,
              workspaces.isEmpty,
              servers.isEmpty else {
            return nil
        }
        return makeDefaultWorkspace(id: InitialWorkspaceBootstrapState.workspaceID)
    }

    func completeInitialWorkspaceBootstrap(after changes: ServerRemoteChanges) {
        guard changes.isFullFetch,
              initialWorkspaceBootstrapState == .awaitingAuthoritativeRemoteState else {
            return
        }
        resolveInitialWorkspaceBootstrap()
    }

    func createInitialWorkspaceForLocalUseIfNeeded() {
        guard initialWorkspaceBootstrapState == .awaitingAuthoritativeRemoteState else {
            return
        }
        guard !hasPendingServerDataMutation else { return }
        guard !localCacheContainsUserData else {
            resolveInitialWorkspaceBootstrap()
            return
        }
        let workspace = makeDefaultWorkspace(id: InitialWorkspaceBootstrapState.workspaceID)
        do {
            try dependencies.localRepository.persist(
                servers: servers,
                workspaces: [workspace]
            )
            replaceCollections(servers: servers, workspaces: [workspace])
            resolveInitialWorkspaceBootstrap()
        } catch {
            logger.error("Failed to persist the initial workspace: \(error.localizedDescription)")
        }
    }

    func servers(in workspace: Workspace, environment: ServerEnvironment?) -> [Server] {
        let workspaceServers = servers.filter { $0.workspaceId == workspace.id }
        guard let environment else { return workspaceServers }
        return workspaceServers.filter { $0.environment.id == environment.id }
    }

    func recentServers(limit: Int = 5) -> [Server] {
        servers
            .filter { $0.lastConnected != nil }
            .sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
            .prefix(max(0, limit))
            .map { $0 }
    }

    func favoriteServers() -> [Server] {
        servers.filter(\.isFavorite)
    }

    func searchServers(_ query: String) -> [Server] {
        guard !query.isEmpty else { return servers }
        let lowercased = query.lowercased()
        return servers.filter {
            $0.name.lowercased().contains(lowercased)
                || $0.host.lowercased().contains(lowercased)
                || $0.username.lowercased().contains(lowercased)
                || $0.tags.contains { $0.lowercased().contains(lowercased) }
        }
    }

    func workspace(withID id: UUID?) -> Workspace? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }
    }

    func server(withID id: UUID) -> Server? {
        servers.first { $0.id == id }
    }

    func assignmentWorkspaces(for server: Server?, hasProAccess: Bool) -> [Workspace] {
        movePolicy(hasProAccess: hasProAccess).assignmentWorkspaces(for: server)
    }

    func moveDestinations(for server: Server, hasProAccess: Bool) -> [Workspace] {
        movePolicy(hasProAccess: hasProAccess).moveDestinations(for: server)
    }

    func resolvedEnvironment(
        for server: Server,
        destination: Workspace,
        preferredEnvironment: ServerEnvironment? = nil
    ) -> ServerEnvironment {
        ServerMoveSupport.resolveEnvironment(
            currentEnvironment: server.environment,
            preferredEnvironment: preferredEnvironment,
            destination: destination
        )
    }

    func moveRequiresEnvironmentFallback(_ server: Server, destination: Workspace) -> Bool {
        ServerMoveSupport.requiresEnvironmentFallback(
            currentEnvironment: server.environment,
            destination: destination
        )
    }

    func moveRestriction(
        for server: Server,
        destination: Workspace,
        hasProAccess: Bool
    ) -> ServerMoveRestriction? {
        guard server.workspaceId != destination.id else { return nil }
        return movePolicy(hasProAccess: hasProAccess).restriction(
            for: server,
            destination: destination
        )
    }

    func canAssignServer(
        _ server: Server,
        to destination: Workspace,
        hasProAccess: Bool
    ) -> Bool {
        movePolicy(hasProAccess: hasProAccess).canAssign(server, to: destination)
    }

    func canAddServer(hasProAccess: Bool) -> Bool {
        freeTierPolicy.canAddServer(serverCount: servers.count, hasProAccess: hasProAccess)
    }

    func canAddWorkspace(hasProAccess: Bool) -> Bool {
        freeTierPolicy.canAddWorkspace(workspaceCount: workspaces.count, hasProAccess: hasProAccess)
    }

    func makeWorkspaceSaveCandidate(
        editing workspace: Workspace?,
        name: String,
        colorHex: String
    ) -> Workspace {
        let date = dependencies.now()
        return Workspace(
            id: workspace?.id ?? dependencies.makeID(),
            name: name,
            colorHex: colorHex,
            icon: workspace?.icon,
            order: workspace?.order ?? workspaces.count,
            environments: workspace?.environments ?? ServerEnvironment.builtInEnvironments,
            lastSelectedEnvironmentId: workspace?.lastSelectedEnvironmentId,
            lastSelectedServerId: workspace?.lastSelectedServerId,
            createdAt: workspace?.createdAt ?? date,
            updatedAt: date
        )
    }

    var freeServerLimit: Int { freeTierPolicy.serverLimit }
    var isLegacyFreePlan: Bool { freeTierPolicy.isLegacyPlan }

    func unlockedServerIDs(hasProAccess: Bool) -> Set<UUID> {
        freeTierPolicy.unlockedServerIDs(servers: servers, hasProAccess: hasProAccess)
    }

    func unlockedWorkspaceIDs(hasProAccess: Bool) -> Set<UUID> {
        freeTierPolicy.unlockedWorkspaceIDs(workspaces: workspaces, hasProAccess: hasProAccess)
    }

    func isServerLocked(_ server: Server, hasProAccess: Bool) -> Bool {
        !hasProAccess && !unlockedServerIDs(hasProAccess: false).contains(server.id)
    }

    func isWorkspaceLocked(_ workspace: Workspace, hasProAccess: Bool) -> Bool {
        !hasProAccess && !unlockedWorkspaceIDs(hasProAccess: false).contains(workspace.id)
    }

    func lockedServersCount(hasProAccess: Bool) -> Int {
        freeTierPolicy.lockedServerCount(serverCount: servers.count, hasProAccess: hasProAccess)
    }

    func lockedWorkspacesCount(hasProAccess: Bool) -> Int {
        freeTierPolicy.lockedWorkspaceCount(workspaceCount: workspaces.count, hasProAccess: hasProAccess)
    }

    func hasLockedItems(hasProAccess: Bool) -> Bool {
        lockedServersCount(hasProAccess: hasProAccess) > 0
            || lockedWorkspacesCount(hasProAccess: hasProAccess) > 0
    }

    func createCustomEnvironment(
        name: String,
        color: String,
        hasProAccess: Bool
    ) throws -> ServerEnvironment {
        guard hasProAccess else {
            throw ServerStateStoreError.proAccessRequiredForCustomEnvironment
        }
        return ServerEnvironment(
            id: dependencies.makeID(),
            name: name,
            shortName: String(name.prefix(4)),
            colorHex: color,
            isBuiltIn: false
        )
    }

    static func backfillCandidates(
        pendingMutations: [ServerPendingMutation],
        cloudWorkspaceIDs: Set<UUID>,
        cloudServerIDs: Set<UUID>,
        deletedWorkspaceIDs: Set<UUID>,
        deletedServerIDs: Set<UUID>
    ) -> (workspaces: [Workspace], servers: [Server]) {
        var pendingWorkspacesByID: [UUID: Workspace] = [:]
        var pendingServersByID: [UUID: Server] = [:]
        for mutation in pendingMutations {
            switch mutation.payload {
            case .workspaceUpsert(let workspace):
                pendingWorkspacesByID[workspace.id] = workspace
            case .serverUpsert(let server):
                pendingServersByID[server.id] = server
            case .initialWorkspaceCreate, .workspaceDelete, .serverDelete:
                continue
            }
        }

        let missingWorkspaces = pendingWorkspacesByID.values.filter {
            !cloudWorkspaceIDs.contains($0.id)
                && !deletedWorkspaceIDs.contains($0.id)
        }
        let missingWorkspaceIDs = Set(missingWorkspaces.map(\.id))
        let missingServers = pendingServersByID.values.filter {
            !cloudServerIDs.contains($0.id)
                && !deletedServerIDs.contains($0.id)
                && !deletedWorkspaceIDs.contains($0.workspaceId)
                && (cloudWorkspaceIDs.contains($0.workspaceId)
                    || missingWorkspaceIDs.contains($0.workspaceId))
        }
        return (
            missingWorkspaces.sorted { $0.id.uuidString < $1.id.uuidString },
            missingServers.sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    static func workspaceForOrphanRepair(
        existingWorkspaces: [Workspace],
        servers: [Server],
        fallbackWorkspace: Workspace
    ) -> Workspace? {
        let workspaceIDs = Set(existingWorkspaces.map(\.id))
        guard servers.contains(where: { !workspaceIDs.contains($0.workspaceId) }) else {
            return nil
        }
        return existingWorkspaces.first ?? fallbackWorkspace
    }

    private var freeTierPolicy: ServerFreeTierPolicy {
        ServerFreeTierPolicy(generation: freePlanGeneration)
    }

    private func movePolicy(hasProAccess: Bool) -> ServerMovePolicy {
        ServerMovePolicy(
            workspaces: workspaces,
            unlockedWorkspaceIDs: unlockedWorkspaceIDs(hasProAccess: hasProAccess),
            hasProAccess: hasProAccess
        )
    }

    private func loadLocalData() {
        let persisted = dependencies.localRepository.loadSnapshot()
        applyPersistedCollections(persisted)
        let pendingJournal = try? dependencies.localRepository.loadServerDataMutationJournal()
        if (try? dependencies.localRepository.loadAmbiguousCloudRecoveryBackup()) != nil {
            updateSnapshot { $0.ambiguousCloudRecovery = .decisionRequired }
        }
        let containsInitialWorkspace = workspaces.contains {
            $0.id == InitialWorkspaceBootstrapState.workspaceID
        } || pendingJournal?.plan.resultingWorkspaces.contains {
            $0.id == InitialWorkspaceBootstrapState.workspaceID
        } == true
        initialWorkspaceBootstrapState = InitialWorkspaceBootstrapState.initial(
            hasResolvedInitialWorkspace: hasResolvedInitialWorkspace,
            hasSeenWelcome: hasSeenWelcome,
            hasLocalWorkspaces: !workspaces.isEmpty,
            hasInitialWorkspace: containsInitialWorkspace,
            hasPendingMutation: pendingJournal != nil
        )
        if !isSyncEnabled {
            createInitialWorkspaceForLocalUseIfNeeded()
        }
    }

    func requireNoPendingServerDataMutation() throws {
        guard !hasPendingServerDataMutation else {
            throw ServerDataMutationTransactionError.recoveryPending
        }
    }

    private func applyPersistedCollections(_ persisted: ServerLocalRepositorySnapshot) {
        var nextSnapshot = snapshot

        switch persisted.servers {
        case .missing:
            nextSnapshot.servers = []
        case .loaded(let servers):
            nextSnapshot.servers = servers
        case .unreadable(let issue):
            nextSnapshot.servers = []
            appendLocalStorageIssue(issue, to: &nextSnapshot)
        }

        switch persisted.workspaces {
        case .missing:
            nextSnapshot.workspaces = []
        case .loaded(let workspaces):
            nextSnapshot.workspaces = workspaces
        case .unreadable(let issue):
            nextSnapshot.workspaces = []
            appendLocalStorageIssue(issue, to: &nextSnapshot)
        }

        snapshot = nextSnapshot
    }

    private func appendLocalStorageIssue(
        _ issue: ServerLocalStorageIssue,
        to snapshot: inout ServerManagerSnapshot
    ) {
        guard !snapshot.localStorageIssues.contains(where: { $0.id == issue.id }) else {
            return
        }
        snapshot.localStorageIssues.append(issue)
        logger.error("Quarantined unreadable local \(issue.collection.rawValue, privacy: .public) data")
    }

    private func persistFreePlanGeneration(_ generation: FreePlanGeneration, reason: String) {
        updateSnapshot { $0.freePlanGeneration = generation }
        dependencies.preferences.freePlanGeneration = generation
        dependencies.freePlanTracker.trackFreePlanGenerationAssigned(
            generation: generation.rawValue,
            serverCount: servers.count,
            reason: reason
        )
    }

    private func makeDefaultWorkspace(id: UUID) -> Workspace {
        let date = dependencies.now()
        return Workspace(
            id: id,
            name: dependencies.defaultWorkspaceName(),
            colorHex: "#007AFF",
            order: 0,
            createdAt: date,
            updatedAt: date
        )
    }

    private func resolveInitialWorkspaceBootstrap() {
        hasResolvedInitialWorkspace = true
        initialWorkspaceBootstrapState = .inactive
    }

    private func dedupedWorkspaces(from workspaces: [Workspace]) -> [Workspace] {
        var byID: [UUID: Workspace] = [:]
        for workspace in workspaces {
            byID[workspace.id] = workspace
        }
        return Array(byID.values).sorted { $0.order < $1.order }
    }

    private func dedupedServers(from servers: [Server]) -> [Server] {
        var byID: [UUID: Server] = [:]
        for server in servers {
            byID[server.id] = server
        }
        return Array(byID.values).sorted { $0.name < $1.name }
    }

    private func updateSnapshot(_ update: (inout ServerManagerSnapshot) -> Void) {
        var nextSnapshot = snapshot
        update(&nextSnapshot)
        snapshot = nextSnapshot
    }

}

private extension Array {
    mutating func moveElements(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty, source.allSatisfy(indices.contains) else { return }
        let originalCount = count
        let movingElements = source.map { self[$0] }
        for index in source.sorted(by: >) {
            remove(at: index)
        }
        let boundedDestination = Swift.max(0, Swift.min(destination, originalCount))
        let removedBeforeDestination = source.count(in: ..<boundedDestination)
        insert(
            contentsOf: movingElements,
            at: boundedDestination - removedBeforeDestination
        )
    }
}
