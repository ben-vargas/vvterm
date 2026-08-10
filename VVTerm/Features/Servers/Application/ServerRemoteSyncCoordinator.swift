import Foundation
import os.log

@MainActor
struct ServerRemoteSyncCoordinatorDependencies {
    let stateStore: ServerStateStore
    let remoteRepository: any ServerRemoteRepository
    let syncRepository: any ServerSyncRepository
    let credentialRepository: any ServerManagerCredentialRepository
    let knownHosts: any ServerKnownHostRepository
    let isRemoteSchemaError: (Error) -> Bool
    let now: () -> Date
    let makeID: () -> UUID
}

@MainActor
final class ServerRemoteSyncCoordinator {
    private nonisolated final class LoadGeneration: Sendable {}

    private nonisolated struct ActiveLoad: Sendable {
        let operationID: UUID
        let generation: LoadGeneration
        let task: Task<Void, Never>
    }

    private struct FullFetchBackfillResult {
        let changes: ServerRemoteChanges
        let canReplaceLocalState: Bool
    }

    private let dependencies: ServerRemoteSyncCoordinatorDependencies
    private let stateStore: ServerStateStore
    private let logger = Logger(
        subsystem: "app.vivy.VVTerm",
        category: "ServerRemoteSyncCoordinator"
    )
    private var activeLoad: ActiveLoad?
    private var startupTask: Task<Void, Never>?

    init(dependencies: ServerRemoteSyncCoordinatorDependencies) {
        self.dependencies = dependencies
        stateStore = dependencies.stateStore
    }

    deinit {
        startupTask?.cancel()
        activeLoad?.task.cancel()
    }

    func startAutomaticLoad() {
        guard startupTask == nil else { return }

        let stateStore = dependencies.stateStore
        let syncRepository = dependencies.syncRepository
        startupTask = Task { [weak self, stateStore, syncRepository] in
            let recoveredPendingDeletion = self?.recoverPendingWorkspaceDeletion() ?? false
            if recoveredPendingDeletion, stateStore.isSyncEnabled {
                await syncRepository.drainPendingMutations()
            }
            guard !Task.isCancelled else { return }
            self?.beginLoadingIfNeeded()
        }
    }

    func loadData() async {
        guard let task = beginLoadingIfNeeded() else { return }
        await task.value
    }

    func handleSyncDisabled() {
        startupTask?.cancel()
        startupTask = nil
        invalidateActiveLoad()
        stateStore.refreshFreePlanGeneration(
            persistCurrentIfNeeded: true,
            reason: "local_only"
        )
    }

    func clearLocalDataAndResync() async {
        logger.info("Clearing local data and re-syncing from CloudKit...")

        if let activeLoad {
            await activeLoad.task.value
        }

        stateStore.clearLocalDataAndState()
        dependencies.syncRepository.clearPendingServerAndWorkspaceMutations()
        await loadData()

        logger.info(
            "Clear and re-sync complete: \(self.stateStore.workspaces.count) workspaces, \(self.stateStore.servers.count) servers"
        )
    }

    func enqueue(_ effect: ServerMutationEffect) {
        switch effect {
        case .serverUpsert(let server):
            dependencies.syncRepository.enqueueServerUpsert(server)
        case .serverDelete(let server):
            dependencies.syncRepository.enqueueServerDelete(server)
        case .workspaceUpsert(let workspace):
            dependencies.syncRepository.enqueueWorkspaceUpsert(workspace)
        }
    }

    func enqueueWorkspaceUpsert(_ workspace: Workspace) {
        dependencies.syncRepository.enqueueWorkspaceUpsert(workspace)
    }

    func drainPendingMutations() async {
        guard stateStore.isSyncEnabled else { return }
        await dependencies.syncRepository.drainPendingMutations()
    }

    func commitWorkspaceDeletion(
        _ plan: WorkspaceDeletionPlan
    ) throws -> WorkspaceDeletionJournal {
        let journal = try workspaceDeletionTransaction.commit(plan)
        applyCommittedWorkspaceDeletion(plan)
        return journal
    }

    func removeKnownHostIfUnused(
        for server: Server,
        excluding deletedServerIDs: Set<UUID> = []
    ) {
        let isStillUsed = stateStore.servers.contains {
            !deletedServerIDs.contains($0.id)
                && $0.id != server.id
                && $0.host == server.host
                && $0.port == server.port
        }
        guard !isStillUsed else { return }
        dependencies.knownHosts.remove(host: server.host, port: server.port)
    }

    @discardableResult
    private func beginLoadingIfNeeded() -> Task<Void, Never>? {
        if let activeLoad {
            return activeLoad.task
        }

        guard stateStore.isSyncEnabled else {
            logger.info("iCloud sync disabled; using local data only")
            stateStore.refreshFreePlanGeneration(
                persistCurrentIfNeeded: true,
                reason: "local_only"
            )
            return nil
        }

        let operationID = stateStore.startLoading(operationID: dependencies.makeID())
        let generation = LoadGeneration()
        let remoteRepository = dependencies.remoteRepository
        let shouldForceFullFetch = stateStore.shouldForceRemoteFullFetchForBootstrap
        let task = Task { [weak self, remoteRepository] in
            do {
                let changes = try await remoteRepository.fetchServerChanges(
                    forceFullFetch: shouldForceFullFetch
                )
                guard !Task.isCancelled else { return }
                await self?.completeLoad(
                    changes,
                    operationID: operationID,
                    generation: generation
                )
            } catch is CancellationError {
                self?.finishCancelledLoad(
                    operationID: operationID,
                    generation: generation
                )
            } catch {
                guard !Task.isCancelled else { return }
                await self?.failLoad(
                    error,
                    operationID: operationID,
                    generation: generation
                )
            }
        }
        activeLoad = ActiveLoad(
            operationID: operationID,
            generation: generation,
            task: task
        )
        return task
    }

    private func invalidateActiveLoad() {
        guard let activeLoad else { return }
        self.activeLoad = nil
        activeLoad.task.cancel()
        stateStore.finishLoading(operationID: activeLoad.operationID)
    }

    private func acceptsLoad(_ generation: LoadGeneration) -> Bool {
        stateStore.isSyncEnabled && activeLoad?.generation === generation
    }

    private func completeLoad(
        _ fetchedChanges: ServerRemoteChanges,
        operationID: UUID,
        generation: LoadGeneration
    ) async {
        guard !Task.isCancelled, acceptsLoad(generation) else { return }
        resolvePendingBootstrapWorkspaceAgainstAuthoritativeFetch(fetchedChanges)
        guard let backfillResult = await backfillMissingLocalRecordsIfNeeded(
            for: fetchedChanges,
            generation: generation
        ) else { return }
        guard !Task.isCancelled, acceptsLoad(generation) else { return }
        let changes = backfillResult.changes

        logger.info(
            "CloudKit returned \(changes.workspaces.count) workspaces, \(changes.servers.count) servers (full fetch: \(changes.isFullFetch))"
        )

        removeKnownHostsDeletedByIncrementalChanges(changes)
        stateStore.applyRemoteChanges(
            changes,
            canReplaceLocalState: backfillResult.canReplaceLocalState
        )
        reconcilePendingServerAndWorkspaceUpsertsAgainstRemote(changes)
        applyPendingSyncOverlay()
        _ = stateStore.reconcilePendingBootstrapWorkspaceState()
        repairOrphanedServers()

        guard !Task.isCancelled, acceptsLoad(generation) else { return }
        await drainPendingMutations()
        guard !Task.isCancelled, acceptsLoad(generation) else { return }

        stateStore.persistCurrentCollections()
        stateStore.refreshFreePlanGeneration(
            persistCurrentIfNeeded: true,
            reason: "cloudkit_load"
        )

        logger.info(
            "Loaded \(self.stateStore.workspaces.count) workspaces and \(self.stateStore.servers.count) servers from CloudKit"
        )
        finishActiveLoad(operationID: operationID, generation: generation)
    }

    private func failLoad(
        _ error: Error,
        operationID: UUID,
        generation: LoadGeneration
    ) async {
        guard !Task.isCancelled, acceptsLoad(generation) else { return }
        logger.error("Failed to load from CloudKit: \(error.localizedDescription)")
        logger.info(
            "Using local data: \(self.stateStore.workspaces.count) workspaces and \(self.stateStore.servers.count) servers"
        )

        if dependencies.remoteRepository.isAvailable && dependencies.isRemoteSchemaError(error) {
            logger.info("Schema error detected, attempting to initialize schema...")
            await initializeRemoteSchema(generation: generation)
        }
        guard !Task.isCancelled, acceptsLoad(generation) else { return }
        activeLoad = nil
        stateStore.failLoading(
            operationID: operationID,
            message: error.localizedDescription
        )
    }

    private func finishCancelledLoad(
        operationID: UUID,
        generation: LoadGeneration
    ) {
        guard activeLoad?.generation === generation else { return }
        activeLoad = nil
        stateStore.finishLoading(operationID: operationID)
    }

    private func finishActiveLoad(
        operationID: UUID,
        generation: LoadGeneration
    ) {
        guard acceptsLoad(generation) else { return }
        activeLoad = nil
        stateStore.finishLoading(operationID: operationID)
    }

    private func backfillMissingLocalRecordsIfNeeded(
        for changes: ServerRemoteChanges,
        generation: LoadGeneration
    ) async -> FullFetchBackfillResult? {
        guard !Task.isCancelled, acceptsLoad(generation) else { return nil }
        guard changes.isFullFetch, dependencies.remoteRepository.isAvailable else {
            return FullFetchBackfillResult(changes: changes, canReplaceLocalState: true)
        }

        if changes.workspaces.isEmpty
            && changes.servers.isEmpty
            && stateStore.localCacheContainsUserData {
            logger.warning(
                "CloudKit full fetch returned no workspaces or servers while local cache contains user data; preserving local state until an explicit recovery path resolves the mismatch"
            )
            return FullFetchBackfillResult(changes: changes, canReplaceLocalState: false)
        }

        let cloudWorkspaceIDs = Set(changes.workspaces.map(\.id))
        let cloudServerIDs = Set(changes.servers.map(\.id))
        let missingCandidates = ServerStateStore.backfillCandidates(
            localWorkspaces: stateStore.workspaces,
            localServers: stateStore.servers,
            cloudWorkspaceIDs: cloudWorkspaceIDs,
            cloudServerIDs: cloudServerIDs,
            transientBootstrapWorkspaceID: stateStore.transientBootstrapWorkspaceID
        )
        let missingWorkspaces = missingCandidates.workspaces
        let missingServers = missingCandidates.servers

        guard !missingWorkspaces.isEmpty || !missingServers.isEmpty else {
            return FullFetchBackfillResult(changes: changes, canReplaceLocalState: true)
        }

        logger.warning(
            "CloudKit full fetch is missing \(missingWorkspaces.count) local workspaces and \(missingServers.count) local servers; queuing recovery upserts and attempting backfill"
        )

        for workspace in missingWorkspaces {
            dependencies.syncRepository.enqueueWorkspaceUpsert(workspace)
        }
        for server in missingServers {
            dependencies.syncRepository.enqueueServerUpsert(server)
        }

        var uploadedWorkspaces: [Workspace] = []
        for workspace in missingWorkspaces {
            guard !Task.isCancelled, acceptsLoad(generation) else { return nil }
            do {
                try await dependencies.remoteRepository.saveWorkspace(workspace)
                guard !Task.isCancelled, acceptsLoad(generation) else { return nil }
                uploadedWorkspaces.append(workspace)
            } catch is CancellationError {
                return nil
            } catch {
                guard acceptsLoad(generation) else { return nil }
                logger.warning(
                    "Failed to backfill workspace \(workspace.name): \(error.localizedDescription)"
                )
            }
        }

        var knownWorkspaceIDs = cloudWorkspaceIDs
        knownWorkspaceIDs.formUnion(uploadedWorkspaces.map(\.id))

        var uploadedServers: [Server] = []
        for server in missingServers {
            guard !Task.isCancelled, acceptsLoad(generation) else { return nil }
            guard knownWorkspaceIDs.contains(server.workspaceId) else {
                logger.warning(
                    "Skipping server backfill for \(server.name) because workspace \(server.workspaceId) is unavailable in CloudKit"
                )
                continue
            }

            do {
                try await dependencies.remoteRepository.saveServer(server)
                guard !Task.isCancelled, acceptsLoad(generation) else { return nil }
                uploadedServers.append(server)
            } catch is CancellationError {
                return nil
            } catch {
                guard acceptsLoad(generation) else { return nil }
                logger.warning(
                    "Failed to backfill server \(server.name): \(error.localizedDescription)"
                )
            }
        }

        let backfillCompleted = uploadedWorkspaces.count == missingWorkspaces.count
            && uploadedServers.count == missingServers.count

        return FullFetchBackfillResult(
            changes: ServerRemoteChanges(
                servers: changes.servers + uploadedServers,
                workspaces: changes.workspaces + uploadedWorkspaces,
                deletedServerIDs: changes.deletedServerIDs,
                deletedWorkspaceIDs: changes.deletedWorkspaceIDs,
                isFullFetch: changes.isFullFetch
            ),
            canReplaceLocalState: backfillCompleted
        )
    }

    private func initializeRemoteSchema(generation: LoadGeneration) async {
        logger.info("Attempting to initialize CloudKit schema by pushing local data...")

        for workspace in stateStore.workspaces {
            guard !Task.isCancelled, acceptsLoad(generation) else { return }
            do {
                try await dependencies.remoteRepository.saveWorkspace(workspace)
                guard !Task.isCancelled, acceptsLoad(generation) else { return }
                logger.info("Pushed workspace to CloudKit: \(workspace.name)")
            } catch is CancellationError {
                return
            } catch {
                guard acceptsLoad(generation) else { return }
                logger.error(
                    "Failed to push workspace \(workspace.name): \(error.localizedDescription)"
                )
            }
        }

        for server in stateStore.servers {
            guard !Task.isCancelled, acceptsLoad(generation) else { return }
            do {
                try await dependencies.remoteRepository.saveServer(server)
                guard !Task.isCancelled, acceptsLoad(generation) else { return }
                logger.info("Pushed server to CloudKit: \(server.name)")
            } catch is CancellationError {
                return
            } catch {
                guard acceptsLoad(generation) else { return }
                logger.error(
                    "Failed to push server \(server.name): \(error.localizedDescription)"
                )
            }
        }

        logger.info("CloudKit schema initialization complete")
    }

    private func resolvePendingBootstrapWorkspaceAgainstAuthoritativeFetch(
        _ changes: ServerRemoteChanges
    ) {
        guard let workspace = stateStore.takePendingBootstrapWorkspaceForAuthoritativeEmptyFetch(changes) else {
            return
        }
        dependencies.syncRepository.enqueueWorkspaceUpsert(workspace)
        logger.info(
            "Promoted pending bootstrap workspace after authoritative CloudKit fetch returned no workspaces"
        )
    }

    private func applyPendingSyncOverlay() {
        stateStore.applyPendingSyncOverlay(
            dependencies.syncRepository.pendingServerMutations()
        )
    }

    private func reconcilePendingServerAndWorkspaceUpsertsAgainstRemote(
        _ changes: ServerRemoteChanges
    ) {
        let snapshot = dependencies.syncRepository.pendingServerMutations()
        let fetchedServersByID = Dictionary(
            uniqueKeysWithValues: changes.servers.map { ($0.id, $0) }
        )
        let fetchedWorkspacesByID = Dictionary(
            uniqueKeysWithValues: changes.workspaces.map { ($0.id, $0) }
        )

        for mutation in snapshot {
            switch mutation.payload {
            case .serverUpsert(let pendingServer):
                guard let fetchedServer = fetchedServersByID[pendingServer.id],
                      fetchedServer.updatedAt >= pendingServer.updatedAt else {
                    continue
                }
                dependencies.syncRepository.removePendingServerMutation(mutation.id)
            case .workspaceUpsert(let pendingWorkspace):
                guard let fetchedWorkspace = fetchedWorkspacesByID[pendingWorkspace.id],
                      fetchedWorkspace.updatedAt >= pendingWorkspace.updatedAt else {
                    continue
                }
                dependencies.syncRepository.removePendingServerMutation(mutation.id)
            case .serverDelete, .workspaceDelete:
                continue
            }
        }
    }

    private var workspaceDeletionTransaction: WorkspaceDeletionTransaction {
        stateStore.makeWorkspaceDeletionTransaction(
            mutationQueue: dependencies.syncRepository,
            credentialCleaner: dependencies.credentialRepository
        )
    }

    private func recoverPendingWorkspaceDeletion() -> Bool {
        do {
            guard let journal = try workspaceDeletionTransaction.resumePending() else {
                return false
            }
            applyCommittedWorkspaceDeletion(journal.plan)
            if journal.phase != .complete {
                logger.error("Workspace deletion recovery remains pending")
            }
            return true
        } catch {
            logger.error(
                "Could not resume workspace deletion: \(error.localizedDescription)"
            )
            return false
        }
    }

    private func applyCommittedWorkspaceDeletion(_ plan: WorkspaceDeletionPlan) {
        let deletedServerIDs = Set(plan.deletedServers.map(\.id))
        for server in plan.deletedServers {
            removeKnownHostIfUnused(for: server, excluding: deletedServerIDs)
        }
        stateStore.applyCommittedWorkspaceDeletion(plan)
    }

    private func removeKnownHostsDeletedByIncrementalChanges(
        _ changes: ServerRemoteChanges
    ) {
        let deletedServerIDs = Set(changes.deletedServerIDs)
        for server in stateStore.servers where deletedServerIDs.contains(server.id) {
            removeKnownHostIfUnused(for: server, excluding: deletedServerIDs)
        }
    }

    private func repairOrphanedServers() {
        let repair = stateStore.repairOrphanedServers(at: dependencies.now())
        guard repair.workspace != nil || !repair.servers.isEmpty else { return }

        if let workspace = repair.workspace, stateStore.isSyncEnabled {
            dependencies.syncRepository.enqueueWorkspaceUpsert(workspace)
            logger.warning(
                "Created repair workspace '\(workspace.name)' to recover orphaned servers"
            )
        }
        for server in repair.servers where stateStore.isSyncEnabled {
            dependencies.syncRepository.enqueueServerUpsert(server)
        }
        logger.warning("Repaired \(repair.servers.count) orphaned servers")
    }
}
