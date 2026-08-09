import Foundation
import Combine
import os.log

@MainActor
final class ServerManager: ObservableObject, ServerMutationRepository {
    private nonisolated final class LoadGeneration: Sendable {}

    private nonisolated struct ActiveLoad: Sendable {
        let operationID: UUID
        let generation: LoadGeneration
        let task: Task<Void, Never>
    }

    let stateStore: ServerStateStore

    var servers: [Server] {
        stateStore.servers
    }

    var workspaces: [Workspace] {
        stateStore.workspaces
    }

    var freePlanGeneration: FreePlanGeneration {
        stateStore.freePlanGeneration
    }

    private let dependencies: ServerManagerDependencies
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ServerManager")
    private var isSyncEnabled: Bool { stateStore.isSyncEnabled }
    private var activeLoad: ActiveLoad?
    private var startupTask: Task<Void, Never>?
    private var stateObservation: AnyCancellable?

    private struct FullFetchBackfillResult {
        let changes: ServerRemoteChanges
        let canReplaceLocalState: Bool
    }

    init(
        dependencies: ServerManagerDependencies,
        startsAutomatically: Bool = true
    ) {
        self.dependencies = dependencies
        stateStore = dependencies.stateStore
        stateObservation = stateStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // Then sync with CloudKit in background
        if startsAutomatically {
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
    }

    deinit {
        startupTask?.cancel()
        activeLoad?.task.cancel()
    }

    private func resolvePendingBootstrapWorkspaceAgainstAuthoritativeFetch(_ changes: ServerRemoteChanges) {
        guard let workspace = stateStore.takePendingBootstrapWorkspaceForAuthoritativeEmptyFetch(changes) else {
            return
        }
        enqueuePendingWorkspaceUpsert(workspace)
        logger.info("Promoted pending bootstrap workspace after authoritative CloudKit fetch returned no workspaces")
    }

    // MARK: - Pending Remote Sync

    private func enqueuePendingServerUpsert(_ server: Server) {
        dependencies.syncRepository.enqueueServerUpsert(server)
    }

    private func enqueuePendingServerDelete(_ server: Server) {
        dependencies.syncRepository.enqueueServerDelete(server)
    }

    private func enqueuePendingWorkspaceUpsert(_ workspace: Workspace) {
        dependencies.syncRepository.enqueueWorkspaceUpsert(workspace)
    }

    private func enqueuePendingWorkspaceDelete(_ workspace: Workspace) {
        dependencies.syncRepository.enqueueWorkspaceDelete(workspace)
    }

    private func applyPendingSyncOverlay() {
        stateStore.applyPendingSyncOverlay(
            dependencies.syncRepository.pendingServerMutations()
        )
    }

    private func reconcilePendingServerAndWorkspaceUpsertsAgainstRemote(_ changes: ServerRemoteChanges) {
        let snapshot = dependencies.syncRepository.pendingServerMutations()
        let fetchedServersByID = Dictionary(uniqueKeysWithValues: changes.servers.map { ($0.id, $0) })
        let fetchedWorkspacesByID = Dictionary(uniqueKeysWithValues: changes.workspaces.map { ($0.id, $0) })

        removeResolvedPendingServerUpserts(in: snapshot, fetchedServersByID: fetchedServersByID)
        removeResolvedPendingWorkspaceUpserts(in: snapshot, fetchedWorkspacesByID: fetchedWorkspacesByID)
    }

    private func removeResolvedPendingServerUpserts(
        in snapshot: [ServerPendingMutation],
        fetchedServersByID: [UUID: Server]
    ) {
        for mutation in snapshot {
            guard case .serverUpsert(let pendingServer) = mutation.payload,
                  let fetchedServer = fetchedServersByID[pendingServer.id] else {
                continue
            }

            if fetchedServer.updatedAt >= pendingServer.updatedAt {
                dependencies.syncRepository.removePendingServerMutation(mutation.id)
            }
        }
    }

    private func removeResolvedPendingWorkspaceUpserts(
        in snapshot: [ServerPendingMutation],
        fetchedWorkspacesByID: [UUID: Workspace]
    ) {
        for mutation in snapshot {
            guard case .workspaceUpsert(let pendingWorkspace) = mutation.payload,
                  let fetchedWorkspace = fetchedWorkspacesByID[pendingWorkspace.id] else {
                continue
            }

            if fetchedWorkspace.updatedAt >= pendingWorkspace.updatedAt {
                dependencies.syncRepository.removePendingServerMutation(mutation.id)
            }
        }
    }

    private func drainPendingRemoteMutations() async {
        guard isSyncEnabled else { return }
        await dependencies.syncRepository.drainPendingMutations()
    }

    private func persistLocalMutations(logMessage: String? = nil) async {
        stateStore.persistCurrentCollections()
        await drainPendingRemoteMutations()
        if let logMessage {
            logger.info("\(logMessage)")
        }
    }

    private func applyMutationResult(_ result: ServerMutationCommandResult) {
        stateStore.applyMutationResult(result)
        enqueueMutationEffect(result.effect)
    }

    private func enqueueMutationEffect(_ effect: ServerMutationEffect) {
        switch effect {
        case .serverUpsert(let server):
            enqueuePendingServerUpsert(server)
        case .serverDelete(let server):
            enqueuePendingServerDelete(server)
        case .workspaceUpsert(let workspace):
            enqueuePendingWorkspaceUpsert(workspace)
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
            guard let journal = try workspaceDeletionTransaction.resumePending() else { return false }
            applyCommittedWorkspaceDeletion(journal.plan)
            if journal.phase != .complete {
                logger.error("Workspace deletion recovery remains pending")
            }
            return true
        } catch {
            logger.error("Could not resume workspace deletion: \(error.localizedDescription)")
            return false
        }
    }

    /// Clear all local data and re-download from CloudKit
    func clearLocalDataAndResync() async {
        logger.info("Clearing local data and re-syncing from CloudKit...")

        if let activeLoad {
            await activeLoad.task.value
        }

        // Clear local storage and the feature-owned observable state.
        stateStore.clearLocalDataAndState()
        dependencies.syncRepository.clearPendingServerAndWorkspaceMutations()

        // Re-fetch from CloudKit
        await loadData()

        logger.info("Clear and re-sync complete: \(self.workspaces.count) workspaces, \(self.servers.count) servers")
    }

    // MARK: - Data Loading

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

    @discardableResult
    private func beginLoadingIfNeeded() -> Task<Void, Never>? {
        if let activeLoad {
            return activeLoad.task
        }

        guard isSyncEnabled else {
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
        isSyncEnabled && activeLoad?.generation === generation
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

        // Merge CloudKit data with local (CloudKit wins for conflicts, dedupe by ID)
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

        // Check for and repair orphaned servers (workspaceId doesn't match any workspace)
        repairOrphanedServers()
        guard !Task.isCancelled, acceptsLoad(generation) else { return }
        await drainPendingRemoteMutations()
        guard !Task.isCancelled, acceptsLoad(generation) else { return }

        // Save merged data locally
        stateStore.persistCurrentCollections()
        stateStore.refreshFreePlanGeneration(
            persistCurrentIfNeeded: true,
            reason: "cloudkit_load"
        )

        logger.info("Loaded \(self.workspaces.count) workspaces and \(self.servers.count) servers from CloudKit")
        finishActiveLoad(operationID: operationID, generation: generation)
    }

    private func failLoad(
        _ error: Error,
        operationID: UUID,
        generation: LoadGeneration
    ) async {
        guard !Task.isCancelled, acceptsLoad(generation) else { return }
        logger.error("Failed to load from CloudKit: \(error.localizedDescription)")
        // Local data is already loaded in init, so nothing to do here
        logger.info("Using local data: \(self.workspaces.count) workspaces and \(self.servers.count) servers")

        // Only try to push local data if it's a schema error (record type not found)
        // This auto-creates schema in development mode
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

    /// If a full fetch is missing local records (common after schema was unavailable),
    /// push the missing records to CloudKit so users don't need to edit each item manually.
    private func backfillMissingLocalRecordsIfNeeded(
        for changes: ServerRemoteChanges,
        generation: LoadGeneration
    ) async -> FullFetchBackfillResult? {
        guard !Task.isCancelled, acceptsLoad(generation) else { return nil }
        guard changes.isFullFetch, dependencies.remoteRepository.isAvailable else {
            return FullFetchBackfillResult(changes: changes, canReplaceLocalState: true)
        }

        if changes.workspaces.isEmpty && changes.servers.isEmpty && stateStore.localCacheContainsUserData {
            logger.warning(
                "CloudKit full fetch returned no workspaces or servers while local cache contains user data; preserving local state until an explicit recovery path resolves the mismatch"
            )
            return FullFetchBackfillResult(changes: changes, canReplaceLocalState: false)
        }

        let cloudWorkspaceIDs = Set(changes.workspaces.map(\.id))
        let cloudServerIDs = Set(changes.servers.map(\.id))
        let missingCandidates = ServerStateStore.backfillCandidates(
            localWorkspaces: workspaces,
            localServers: servers,
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
            enqueuePendingWorkspaceUpsert(workspace)
        }

        for server in missingServers {
            enqueuePendingServerUpsert(server)
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
                logger.warning("Failed to backfill workspace \(workspace.name): \(error.localizedDescription)")
            }
        }

        var knownWorkspaceIDs = cloudWorkspaceIDs
        knownWorkspaceIDs.formUnion(uploadedWorkspaces.map(\.id))

        var uploadedServers: [Server] = []
        for server in missingServers {
            guard !Task.isCancelled, acceptsLoad(generation) else { return nil }
            guard knownWorkspaceIDs.contains(server.workspaceId) else {
                logger.warning("Skipping server backfill for \(server.name) because workspace \(server.workspaceId) is unavailable in CloudKit")
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
                logger.warning("Failed to backfill server \(server.name): \(error.localizedDescription)")
            }
        }

        let backfillCompleted = uploadedWorkspaces.count == missingWorkspaces.count &&
            uploadedServers.count == missingServers.count

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

    private func removeKnownHostIfUnused(for server: Server, excluding deletedServerIDs: Set<UUID> = []) {
        let isStillUsed = servers.contains {
            !deletedServerIDs.contains($0.id)
                && $0.id != server.id
                && $0.host == server.host
                && $0.port == server.port
        }
        guard !isStillUsed else { return }
        dependencies.knownHosts.remove(host: server.host, port: server.port)
    }

    private func removeKnownHostsDeletedByIncrementalChanges(_ changes: ServerRemoteChanges) {
        let deletedServerIDs = Set(changes.deletedServerIDs)
        for server in servers where deletedServerIDs.contains(server.id) {
            removeKnownHostIfUnused(for: server, excluding: deletedServerIDs)
        }
    }

    /// Repairs servers that reference non-existent workspaces by reassigning them to the first available workspace
    private func repairOrphanedServers() {
        let repair = stateStore.repairOrphanedServers(at: dependencies.now())
        guard repair.workspace != nil || !repair.servers.isEmpty else { return }

        if let workspace = repair.workspace, isSyncEnabled {
            enqueuePendingWorkspaceUpsert(workspace)
            logger.warning("Created repair workspace '\(workspace.name)' to recover orphaned servers")
        }
        for server in repair.servers where isSyncEnabled {
            enqueuePendingServerUpsert(server)
        }
        logger.warning("Repaired \(repair.servers.count) orphaned servers")
    }

    /// Push local data to CloudKit to auto-create schema in development mode
    private func initializeRemoteSchema(generation: LoadGeneration) async {
        logger.info("Attempting to initialize CloudKit schema by pushing local data...")

        // Push workspaces first
        for workspace in workspaces {
            guard !Task.isCancelled, acceptsLoad(generation) else { return }
            do {
                try await dependencies.remoteRepository.saveWorkspace(workspace)
                guard !Task.isCancelled, acceptsLoad(generation) else { return }
                logger.info("Pushed workspace to CloudKit: \(workspace.name)")
            } catch is CancellationError {
                return
            } catch {
                guard acceptsLoad(generation) else { return }
                logger.error("Failed to push workspace \(workspace.name): \(error.localizedDescription)")
            }
        }

        // Push servers
        for server in servers {
            guard !Task.isCancelled, acceptsLoad(generation) else { return }
            do {
                try await dependencies.remoteRepository.saveServer(server)
                guard !Task.isCancelled, acceptsLoad(generation) else { return }
                logger.info("Pushed server to CloudKit: \(server.name)")
            } catch is CancellationError {
                return
            } catch {
                guard acceptsLoad(generation) else { return }
                logger.error("Failed to push server \(server.name): \(error.localizedDescription)")
            }
        }

        logger.info("CloudKit schema initialization complete")
    }

    // MARK: - Server CRUD

    func validate(_ mutation: ServerMutation, hasProAccess: Bool) throws {
        switch mutation {
        case .create:
            guard stateStore.canAddServer(hasProAccess: hasProAccess) else {
                throw VVTermError.proRequired(.unlimitedServers)
            }
        case .update(let server):
            guard stateStore.server(withID: server.id) != nil else {
                throw VVTermError.serverNotFound
            }
        }
    }

    func apply(_ mutation: ServerMutation) async throws -> Server {
        let command: ServerMutationCommand
        switch mutation {
        case .create(let server):
            command = .insertServer(server)

        case .update(let server):
            command = .updateServer(server)
        }
        let result = try stateStore.commitMutation(
            command,
            now: dependencies.now()
        )
        enqueueMutationEffect(result.effect)
        await drainPendingRemoteMutations()

        guard case .serverUpsert(let savedServer) = result.effect else {
            preconditionFailure("A server save command must produce a server upsert")
        }
        if case .create = mutation {
            stateStore.promotePendingBootstrapWorkspaceIfNeeded(
                for: savedServer.workspaceId,
                reason: "adding a server"
            )
        }
        let action: String
        switch mutation {
        case .create:
            action = "Added"
        case .update:
            action = "Updated"
        }
        logger.info("\(action) server: \(savedServer.name)")
        return savedServer
    }

    func deleteServer(_ server: Server) async throws {
        guard let storedServer = servers.first(where: { $0.id == server.id }) else { return }
        guard await dependencies.actionAuthorizer.authorize(
            storedServer,
            for: .delete
        ) else {
            throw VVTermError.authorizationRequired
        }

        try await deleteServerData(storedServer)
    }

    private func deleteServerData(_ server: Server) async throws {
        try dependencies.credentialRepository.deleteCredentials(for: server.id)

        removeKnownHostIfUnused(for: server)
        let result = try stateStore.planMutation(
            .deleteServer(server.id),
            now: dependencies.now()
        )
        applyMutationResult(result)
        await persistLocalMutations(logMessage: "Deleted server: \(server.name)")
    }

    func updateLastConnected(for server: Server) async {
        stateStore.updateLastConnected(for: server.id, at: dependencies.now())
    }

    // MARK: - Workspace CRUD

    func addWorkspace(_ workspace: Workspace, hasProAccess: Bool) async throws {
        guard stateStore.canAddWorkspace(hasProAccess: hasProAccess) else {
            throw VVTermError.proRequired(.unlimitedWorkspaces)
        }

        let result = try stateStore.commitMutation(
            .insertWorkspace(workspace),
            now: dependencies.now()
        )
        enqueueMutationEffect(result.effect)
        stateStore.clearPendingBootstrapWorkspace(reason: "adding a workspace")
        await drainPendingRemoteMutations()
        logger.info("Added workspace: \(workspace.name)")
    }

    func updateWorkspace(_ workspace: Workspace) async throws {
        let result = try stateStore.commitMutation(
            .updateWorkspace(workspace),
            now: dependencies.now()
        )
        enqueueMutationEffect(result.effect)
        stateStore.promotePendingBootstrapWorkspaceIfNeeded(
            for: workspace.id,
            reason: "updating workspace metadata"
        )
        await drainPendingRemoteMutations()
        logger.info("Updated workspace: \(workspace.name)")
    }

    func deleteWorkspace(_ workspace: Workspace) async throws {
        let initialDeletedServers = servers.filter { $0.workspaceId == workspace.id }
        guard let plan = WorkspaceDeletionPlan(
            workspaceID: workspace.id,
            servers: servers,
            workspaces: workspaces,
            id: dependencies.makeID(),
            mutationIDs: initialDeletedServers.map { _ in dependencies.makeID() }
                + [dependencies.makeID()],
            mutationDate: dependencies.now()
        ) else {
            return
        }

        for server in plan.deletedServers where server.requiresBiometricUnlock {
            guard await dependencies.actionAuthorizer.authorize(
                server,
                for: .delete
            ) else {
                throw VVTermError.authorizationRequired
            }
        }

        let currentDeletedServers = servers.filter { $0.workspaceId == workspace.id }
        guard let currentPlan = WorkspaceDeletionPlan(
            workspaceID: workspace.id,
            servers: servers,
            workspaces: workspaces,
            id: dependencies.makeID(),
            mutationIDs: currentDeletedServers.map { _ in dependencies.makeID() }
                + [dependencies.makeID()],
            mutationDate: dependencies.now()
        ), plan.hasSameDeletionSnapshot(as: currentPlan) else {
            throw VVTermError.workspaceDeletionChanged
        }

        let journal = try workspaceDeletionTransaction.commit(currentPlan)
        applyCommittedWorkspaceDeletion(currentPlan)
        await drainPendingRemoteMutations()

        guard journal.phase == .complete else {
            logger.error("Workspace deletion committed with pending recovery work")
            throw VVTermError.workspaceDeletionRecoveryPending
        }
        logger.info("Deleted workspace: \(plan.workspace.name)")
    }

    private func applyCommittedWorkspaceDeletion(_ plan: WorkspaceDeletionPlan) {
        let deletedServerIDs = Set(plan.deletedServers.map(\.id))
        for server in plan.deletedServers {
            removeKnownHostIfUnused(for: server, excluding: deletedServerIDs)
        }
        stateStore.applyCommittedWorkspaceDeletion(plan)
    }

    func reorderWorkspaces(from source: IndexSet, to destination: Int) async throws {
        let reordered = stateStore.reorderWorkspaces(
            from: source,
            to: destination,
            at: dependencies.now()
        )
        for workspace in reordered {
            enqueuePendingWorkspaceUpsert(workspace)
        }
        await drainPendingRemoteMutations()
        logger.info("Reordered workspaces")
    }

    // MARK: - Queries

    func servers(in workspace: Workspace, environment: ServerEnvironment?) -> [Server] {
        stateStore.servers(in: workspace, environment: environment)
    }

    func workspace(withId id: UUID?) -> Workspace? {
        stateStore.workspace(withID: id)
    }

    func server(id: UUID) -> Server? {
        stateStore.server(withID: id)
    }

    func moveServer(
        _ server: Server,
        to destination: Workspace,
        preferredEnvironment: ServerEnvironment? = nil,
        hasProAccess: Bool
    ) async throws -> Server {
        guard let refreshedDestination = stateStore.workspace(withID: destination.id) else {
            throw VVTermError.moveNotAllowed(.destinationUnavailable)
        }

        if let restriction = moveRestriction(
            for: server,
            destination: refreshedDestination,
            hasProAccess: hasProAccess
        ) {
            throw restriction
        }

        let sourceWorkspace = stateStore.workspace(withID: server.workspaceId)
        let resolvedEnvironment = stateStore.resolvedEnvironment(
            for: server,
            destination: refreshedDestination,
            preferredEnvironment: preferredEnvironment
        )

        var updatedServer = server
        updatedServer.workspaceId = refreshedDestination.id
        updatedServer.environment = resolvedEnvironment

        _ = try await apply(.update(updatedServer))
        try await updateWorkspaceSelectionMetadataAfterMove(
            serverId: server.id,
            from: sourceWorkspace,
            to: refreshedDestination
        )

        return updatedServer
    }

    // MARK: - Pro Limits

    var freeServerLimit: Int {
        stateStore.freeServerLimit
    }

    /// Check if a specific server is locked (over free tier limit)
    func isServerLocked(_ server: Server, hasProAccess: Bool) -> Bool {
        stateStore.isServerLocked(server, hasProAccess: hasProAccess)
    }

    /// Check if a specific workspace is locked (over free tier limit)
    func isWorkspaceLocked(_ workspace: Workspace, hasProAccess: Bool) -> Bool {
        stateStore.isWorkspaceLocked(workspace, hasProAccess: hasProAccess)
    }

    private func moveRestriction(
        for server: Server,
        destination: Workspace,
        hasProAccess: Bool
    ) -> VVTermError? {
        guard server.workspaceId != destination.id else { return nil }

        switch stateStore.moveRestriction(
            for: server,
            destination: destination,
            hasProAccess: hasProAccess
        ) {
        case nil:
            return nil
        case .lockedWorkspace:
            return VVTermError.proRequired(.moveIntoLockedWorkspace)
        case .unavailable:
            return VVTermError.moveNotAllowed(.unavailable)
        }
    }

    private func updateWorkspaceSelectionMetadataAfterMove(
        serverId: UUID,
        from sourceWorkspace: Workspace?,
        to destinationWorkspace: Workspace
    ) async throws {
        if let sourceWorkspace,
           sourceWorkspace.id != destinationWorkspace.id,
           sourceWorkspace.lastSelectedServerId == serverId {
            var updatedSource = sourceWorkspace
            updatedSource.lastSelectedServerId = nil
            try await updateWorkspace(updatedSource)
        }

        if destinationWorkspace.lastSelectedServerId != serverId {
            var updatedDestination = destinationWorkspace
            updatedDestination.lastSelectedServerId = serverId
            try await updateWorkspace(updatedDestination)
        }
    }

    func updateEnvironment(_ environment: ServerEnvironment, in workspace: Workspace) async throws -> Workspace {
        var updatedWorkspace = workspace
        if let envIndex = updatedWorkspace.environments.firstIndex(where: { $0.id == environment.id }) {
            updatedWorkspace.environments[envIndex] = environment
        } else {
            return updatedWorkspace
        }

        try await updateWorkspace(updatedWorkspace)

        let serversToUpdate = servers.filter { $0.workspaceId == workspace.id && $0.environment.id == environment.id }
        for server in serversToUpdate {
            var updatedServer = server
            updatedServer.environment = environment
            _ = try await apply(.update(updatedServer))
        }

        return updatedWorkspace
    }

    func deleteEnvironment(
        _ environment: ServerEnvironment,
        in workspace: Workspace
    ) async throws -> Workspace {
        try await deleteEnvironment(environment, in: workspace, fallback: .production)
    }

    func deleteEnvironment(
        _ environment: ServerEnvironment,
        in workspace: Workspace,
        fallback: ServerEnvironment
    ) async throws -> Workspace {
        var updatedWorkspace = workspace
        updatedWorkspace.environments.removeAll { $0.id == environment.id }
        if updatedWorkspace.lastSelectedEnvironmentId == environment.id {
            updatedWorkspace.lastSelectedEnvironmentId = fallback.id
        }

        try await updateWorkspace(updatedWorkspace)

        let serversToUpdate = servers.filter { $0.workspaceId == workspace.id && $0.environment.id == environment.id }
        for server in serversToUpdate {
            var updatedServer = server
            updatedServer.environment = fallback
            _ = try await apply(.update(updatedServer))
        }

        return updatedWorkspace
    }

    func handleAppLanguageChange() {
        stateStore.handleAppLanguageChange()
    }
}
