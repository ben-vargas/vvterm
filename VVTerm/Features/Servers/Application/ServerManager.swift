import Foundation
import CloudKit
import Combine
import os.log

nonisolated struct ServerDataLoadState: Equatable, Sendable {
    nonisolated enum Phase: Equatable, Sendable {
        case idle
        case loading(operationID: UUID)
        case failed(message: String)
    }

    private(set) var phase: Phase = .idle

    var isLoading: Bool {
        if case .loading = phase {
            return true
        }
        return false
    }

    var errorMessage: String? {
        if case .failed(let message) = phase {
            return message
        }
        return nil
    }

    mutating func start() -> UUID {
        let operationID = UUID()
        phase = .loading(operationID: operationID)
        return operationID
    }

    @discardableResult
    mutating func finish(operationID: UUID) -> Bool {
        guard case .loading(operationID) = phase else {
            return false
        }
        phase = .idle
        return true
    }

    @discardableResult
    mutating func fail(operationID: UUID, message: String) -> Bool {
        guard case .loading(operationID) = phase else {
            return false
        }
        phase = .failed(message: message)
        return true
    }

    mutating func reset() {
        phase = .idle
    }
}

@MainActor
final class ServerManager: ObservableObject, ServerMutationRepository {
    static let shared = ServerManager()

    @Published var servers: [Server] = []
    @Published var workspaces: [Workspace] = []
    @Published private(set) var loadState = ServerDataLoadState()
    @Published private(set) var localStorageIssues: [ServerLocalStorageIssue] = []
    @Published private(set) var freePlanGeneration: FreePlanGeneration = ServerManager.loadStoredFreePlanGeneration() ?? .currentOneServer

    var isLoading: Bool { loadState.isLoading }
    var error: String? { loadState.errorMessage }

    private let cloudKit = CloudKitManager.shared
    private let syncCoordinator = CloudKitSyncCoordinator.shared
    private let keychain = KeychainManager.shared
    private let localStore = ServerLocalStore()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ServerManager")
    private var isSyncEnabled: Bool { SyncSettings.isEnabled }
    private var activeLoad: (id: UUID, task: Task<Void, Never>)?

    // Local storage keys
    private let serversKey = CloudKitSyncConstants.serverStorageKey
    private let workspacesKey = CloudKitSyncConstants.workspaceStorageKey
    private let didBootstrapDefaultWorkspaceKey = CloudKitSyncConstants.didBootstrapDefaultWorkspaceKey
    private let pendingBootstrapWorkspaceIDKey = CloudKitSyncConstants.pendingBootstrapWorkspaceIDKey
    private let hasSeenWelcomeKey = "hasSeenWelcome"

    private struct FullFetchBackfillResult {
        let changes: CloudKitChanges
        let canReplaceLocalState: Bool
    }

    private init() {
        // Load local data first (fast)
        loadLocalData()
        refreshFreePlanGeneration(persistCurrentIfNeeded: !isSyncEnabled, reason: "local_load")
        // Then sync with CloudKit in background
        Task {
            await resumePendingWorkspaceDeletion()
            await loadData()
        }
    }

    // MARK: - Local Storage

    private func loadLocalData() {
        var shouldPersist = false

        switch localStore.loadServers() {
        case .missing:
            break
        case .loaded(let decoded):
            servers = decoded
            logger.info("Loaded \(decoded.count) servers from local storage")
        case .unreadable(let issue):
            recordLocalStorageIssue(issue)
        }

        switch localStore.loadWorkspaces() {
        case .missing:
            break
        case .loaded(let decoded):
            workspaces = decoded
            logger.info("Loaded \(decoded.count) workspaces from local storage")
        case .unreadable(let issue):
            recordLocalStorageIssue(issue)
        }

        shouldPersist = reconcilePendingBootstrapWorkspaceState() || shouldPersist

        if Self.shouldCreateBootstrapWorkspace(
            didBootstrapDefaultWorkspace: didBootstrapDefaultWorkspace,
            hasSeenWelcome: hasSeenWelcome,
            hasLocalWorkspaces: !workspaces.isEmpty
        ) {
            createBootstrapWorkspace()
            didBootstrapDefaultWorkspace = true
            shouldPersist = true
        }

        if shouldPersist {
            saveLocalData()
        }
    }

    private func saveLocalData() {
        do {
            try localStore.storeServers(servers)
            try localStore.storeWorkspaces(workspaces)
        } catch {
            logger.error("Failed to encode local server data: \(error.localizedDescription)")
        }
    }

    private func recordLocalStorageIssue(_ issue: ServerLocalStorageIssue) {
        guard !localStorageIssues.contains(where: { $0.id == issue.id }) else {
            return
        }
        localStorageIssues.append(issue)
        logger.error(
            "Quarantined unreadable local \(issue.collection.rawValue, privacy: .public) data"
        )
    }

    func dismissLocalStorageIssues() {
        localStorageIssues.removeAll()
    }

    private var didBootstrapDefaultWorkspace: Bool {
        get { UserDefaults.standard.bool(forKey: didBootstrapDefaultWorkspaceKey) }
        set { UserDefaults.standard.set(newValue, forKey: didBootstrapDefaultWorkspaceKey) }
    }

    private var hasSeenWelcome: Bool {
        UserDefaults.standard.bool(forKey: hasSeenWelcomeKey)
    }

    private static func loadStoredFreePlanGeneration() -> FreePlanGeneration? {
        guard let rawValue = UserDefaults.standard.string(forKey: FreeTierLimits.planGenerationStorageKey) else {
            return nil
        }
        return FreePlanGeneration(rawValue: rawValue)
    }

    private func refreshFreePlanGeneration(persistCurrentIfNeeded: Bool, reason: String) {
        if let storedGeneration = Self.loadStoredFreePlanGeneration() {
            freePlanGeneration = storedGeneration
            return
        }

        if hasLegacyFreePlanEvidence {
            persistFreePlanGeneration(.legacyThreeServers, reason: reason)
        } else if persistCurrentIfNeeded {
            persistFreePlanGeneration(.currentOneServer, reason: reason)
        } else {
            freePlanGeneration = .currentOneServer
        }
    }

    private var hasLegacyFreePlanEvidence: Bool {
        servers.contains { $0.createdAt < FreeTierLimits.currentOneServerPlanCutoff }
    }

    private func persistFreePlanGeneration(_ generation: FreePlanGeneration, reason: String) {
        freePlanGeneration = generation
        UserDefaults.standard.set(generation.rawValue, forKey: FreeTierLimits.planGenerationStorageKey)
        AnalyticsTracker.shared.trackFreePlanGenerationAssigned(
            generation: generation.rawValue,
            serverCount: servers.count,
            reason: reason
        )
    }

    private var pendingBootstrapWorkspaceID: UUID? {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: pendingBootstrapWorkspaceIDKey) else {
                return nil
            }
            return UUID(uuidString: rawValue)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: pendingBootstrapWorkspaceIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: pendingBootstrapWorkspaceIDKey)
            }
        }
    }

    private var transientBootstrapWorkspaceID: UUID? {
        pendingBootstrapWorkspaceID
    }

    private func createBootstrapWorkspace() {
        let workspace = createDefaultWorkspace()
        workspaces = [workspace]

        if isSyncEnabled {
            pendingBootstrapWorkspaceID = workspace.id
            logger.info("Created pending default workspace: \(workspace.name)")
        } else {
            pendingBootstrapWorkspaceID = nil
            logger.info("Created default workspace: \(workspace.name)")
        }
    }

    @discardableResult
    private func reconcilePendingBootstrapWorkspaceState() -> Bool {
        guard let pendingBootstrapWorkspaceID else {
            return false
        }

        guard workspaces.contains(where: { $0.id == pendingBootstrapWorkspaceID }) else {
            self.pendingBootstrapWorkspaceID = nil
            return true
        }

        if servers.contains(where: { $0.workspaceId == pendingBootstrapWorkspaceID }) || workspaces.count > 1 {
            self.pendingBootstrapWorkspaceID = nil
            logger.info("Promoted pending bootstrap workspace \(pendingBootstrapWorkspaceID.uuidString) into regular local state")
            return true
        }

        return refreshPendingBootstrapWorkspaceLocalizationIfNeeded()
    }

    @discardableResult
    private func refreshPendingBootstrapWorkspaceLocalizationIfNeeded() -> Bool {
        guard let pendingBootstrapWorkspaceID,
              let index = workspaces.firstIndex(where: { $0.id == pendingBootstrapWorkspaceID }) else {
            return false
        }

        let localizedName = AppLanguage.localizedString("My Servers")
        guard workspaces[index].name != localizedName,
              Self.isCanonicalDefaultWorkspaceCandidate(workspaces[index]) else {
            return false
        }

        workspaces[index].name = localizedName
        logger.info("Updated pending bootstrap workspace name to match selected app language")
        return true
    }

    private func promotePendingBootstrapWorkspaceIfNeeded(for workspaceID: UUID, reason: String) {
        guard pendingBootstrapWorkspaceID == workspaceID else { return }
        pendingBootstrapWorkspaceID = nil
        logger.info("Promoted pending bootstrap workspace after \(reason)")
    }

    private func resolvePendingBootstrapWorkspaceAgainstAuthoritativeFetch(_ changes: CloudKitChanges) {
        guard changes.isFullFetch,
              changes.workspaces.isEmpty,
              let pendingBootstrapWorkspaceID,
              let workspace = workspaces.first(where: { $0.id == pendingBootstrapWorkspaceID }) else {
            return
        }

        self.pendingBootstrapWorkspaceID = nil
        enqueuePendingWorkspaceUpsert(workspace)
        logger.info("Promoted pending bootstrap workspace after authoritative CloudKit fetch returned no workspaces")
    }

    // MARK: - Pending CloudKit Sync

    private func enqueuePendingServerUpsert(_ server: Server) {
        syncCoordinator.enqueueServerUpsert(server)
    }

    private func enqueuePendingServerDelete(_ server: Server) {
        syncCoordinator.enqueueServerDelete(server)
    }

    private func enqueuePendingWorkspaceUpsert(_ workspace: Workspace) {
        syncCoordinator.enqueueWorkspaceUpsert(workspace)
    }

    private func enqueuePendingWorkspaceDelete(_ workspace: Workspace) {
        syncCoordinator.enqueueWorkspaceDelete(workspace)
    }

    private func applyPendingSyncOverlay() {
        let snapshot = syncCoordinator.snapshot()
        applyPendingUpsertOverlay(in: snapshot)
        applyPendingDeleteOverlay(in: snapshot)
    }

    private func applyPendingUpsertOverlay(in snapshot: [PendingCloudKitMutation]) {
        for mutation in snapshot {
            guard case .workspaceUpsert(let workspace) = mutation.payload else { continue }
            applyPendingWorkspaceUpsert(workspace)
        }

        for mutation in snapshot {
            guard case .serverUpsert(let server) = mutation.payload else { continue }
            applyPendingServerUpsert(server)
        }
    }

    private func applyPendingDeleteOverlay(in snapshot: [PendingCloudKitMutation]) {
        for mutation in snapshot {
            guard case .serverDelete(let server) = mutation.payload else { continue }
            applyPendingServerDelete(server.id)
        }

        for mutation in snapshot {
            guard case .workspaceDelete(let workspace) = mutation.payload else { continue }
            applyPendingWorkspaceDelete(workspace.id)
        }
    }

    private func reconcilePendingServerAndWorkspaceUpsertsAgainstCloudKit(_ changes: CloudKitChanges) {
        let snapshot = syncCoordinator.snapshot()
        let fetchedServersByID = Dictionary(uniqueKeysWithValues: changes.servers.map { ($0.id, $0) })
        let fetchedWorkspacesByID = Dictionary(uniqueKeysWithValues: changes.workspaces.map { ($0.id, $0) })

        removeResolvedPendingServerUpserts(in: snapshot, fetchedServersByID: fetchedServersByID)
        removeResolvedPendingWorkspaceUpserts(in: snapshot, fetchedWorkspacesByID: fetchedWorkspacesByID)
    }

    private func removeResolvedPendingServerUpserts(
        in snapshot: [PendingCloudKitMutation],
        fetchedServersByID: [UUID: Server]
    ) {
        for mutation in snapshot {
            guard case .serverUpsert(let pendingServer) = mutation.payload,
                  let fetchedServer = fetchedServersByID[pendingServer.id] else {
                continue
            }

            if fetchedServer.updatedAt >= pendingServer.updatedAt {
                syncCoordinator.removePendingMutation(mutation.id)
            }
        }
    }

    private func removeResolvedPendingWorkspaceUpserts(
        in snapshot: [PendingCloudKitMutation],
        fetchedWorkspacesByID: [UUID: Workspace]
    ) {
        for mutation in snapshot {
            guard case .workspaceUpsert(let pendingWorkspace) = mutation.payload,
                  let fetchedWorkspace = fetchedWorkspacesByID[pendingWorkspace.id] else {
                continue
            }

            if fetchedWorkspace.updatedAt >= pendingWorkspace.updatedAt {
                syncCoordinator.removePendingMutation(mutation.id)
            }
        }
    }

    private func applyPendingServerUpsert(_ server: Server) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
    }

    private func applyPendingServerDelete(_ serverID: UUID) {
        servers.removeAll { $0.id == serverID }
    }

    private func applyPendingWorkspaceUpsert(_ workspace: Workspace) {
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }
    }

    private func applyPendingWorkspaceDelete(_ workspaceID: UUID) {
        workspaces.removeAll { $0.id == workspaceID }
        servers.removeAll { $0.workspaceId == workspaceID }
    }

    private func drainPendingCloudKitMutations() async {
        guard isSyncEnabled else { return }
        await syncCoordinator.drainPendingMutations()
    }

    private func persistLocalMutations(logMessage: String? = nil) async {
        saveLocalData()
        await drainPendingCloudKitMutations()
        if let logMessage {
            logger.info("\(logMessage)")
        }
    }

    private var workspaceDeletionTransaction: WorkspaceDeletionTransaction {
        WorkspaceDeletionTransaction(
            store: localStore,
            mutationQueue: syncCoordinator,
            credentialCleaner: keychain
        )
    }

    private func resumePendingWorkspaceDeletion() async {
        do {
            guard let journal = try workspaceDeletionTransaction.resumePending() else { return }
            applyCommittedWorkspaceDeletion(journal.plan)
            if journal.phase != .complete {
                logger.error("Workspace deletion recovery remains pending")
            }
            await drainPendingCloudKitMutations()
        } catch {
            logger.error("Could not resume workspace deletion: \(error.localizedDescription)")
        }
    }

    /// Clear all local data and re-download from CloudKit
    func clearLocalDataAndResync() async {
        logger.info("Clearing local data and re-syncing from CloudKit...")

        if let activeLoad {
            await activeLoad.task.value
            if self.activeLoad?.id == activeLoad.id {
                self.activeLoad = nil
            }
        }

        // Clear local storage
        UserDefaults.standard.removeObject(forKey: serversKey)
        UserDefaults.standard.removeObject(forKey: workspacesKey)
        pendingBootstrapWorkspaceID = nil
        syncCoordinator.clearPendingServerAndWorkspaceMutations()

        // Clear in-memory data
        servers = []
        workspaces = []
        loadState.reset()

        // Re-fetch from CloudKit
        await loadData()

        logger.info("Clear and re-sync complete: \(self.workspaces.count) workspaces, \(self.servers.count) servers")
    }

    // MARK: - Data Loading

    func loadData() async {
        if let activeLoad {
            await activeLoad.task.value
            return
        }

        let operationID = loadState.start()
        let task = Task { [weak self] in
            guard let self else { return }
            await performLoad(operationID: operationID)
        }
        activeLoad = (operationID, task)
        await task.value

        if activeLoad?.id == operationID {
            activeLoad = nil
        }
    }

    private func performLoad(operationID: UUID) async {

        guard isSyncEnabled else {
            logger.info("iCloud sync disabled; using local data only")
            refreshFreePlanGeneration(persistCurrentIfNeeded: true, reason: "local_only")
            loadState.finish(operationID: operationID)
            return
        }

        do {
            let shouldForceFullFetch = shouldForceCloudKitFullFetchForBootstrap
            let fetchedChanges = try await cloudKit.fetchChanges(forceFullFetch: shouldForceFullFetch)
            resolvePendingBootstrapWorkspaceAgainstAuthoritativeFetch(fetchedChanges)
            let backfillResult = await backfillMissingLocalRecordsIfNeeded(for: fetchedChanges)
            let changes = backfillResult.changes

            // Merge CloudKit data with local (CloudKit wins for conflicts, dedupe by ID)
            logger.info(
                "CloudKit returned \(changes.workspaces.count) workspaces, \(changes.servers.count) servers (full fetch: \(changes.isFullFetch))"
            )

            applyCloudKitChanges(changes, canReplaceLocalState: backfillResult.canReplaceLocalState)
            reconcilePendingServerAndWorkspaceUpsertsAgainstCloudKit(changes)
            applyPendingSyncOverlay()
            _ = reconcilePendingBootstrapWorkspaceState()

            // Check for and repair orphaned servers (workspaceId doesn't match any workspace)
            await repairOrphanedServers()
            await drainPendingCloudKitMutations()

            // Save merged data locally
            saveLocalData()
            refreshFreePlanGeneration(persistCurrentIfNeeded: true, reason: "cloudkit_load")

            logger.info("Loaded \(self.workspaces.count) workspaces and \(self.servers.count) servers from CloudKit")
            loadState.finish(operationID: operationID)
        } catch {
            logger.error("Failed to load from CloudKit: \(error.localizedDescription)")
            // Local data is already loaded in init, so nothing to do here
            logger.info("Using local data: \(self.workspaces.count) workspaces and \(self.servers.count) servers")

            // Only try to push local data if it's a schema error (record type not found)
            // This auto-creates schema in development mode
            if cloudKit.isAvailable && CloudKitManager.isSchemaError(error) {
                logger.info("Schema error detected, attempting to initialize schema...")
                await initializeCloudKitSchema()
            }
            loadState.fail(operationID: operationID, message: error.localizedDescription)
        }
    }

    /// If a full fetch is missing local records (common after schema was unavailable),
    /// push the missing records to CloudKit so users don't need to edit each item manually.
    private func backfillMissingLocalRecordsIfNeeded(for changes: CloudKitChanges) async -> FullFetchBackfillResult {
        guard changes.isFullFetch, isSyncEnabled, cloudKit.isAvailable else {
            return FullFetchBackfillResult(changes: changes, canReplaceLocalState: true)
        }

        if changes.workspaces.isEmpty && changes.servers.isEmpty && localCacheContainsUserData {
            logger.warning(
                "CloudKit full fetch returned no workspaces or servers while local cache contains user data; preserving local state until an explicit recovery path resolves the mismatch"
            )
            return FullFetchBackfillResult(changes: changes, canReplaceLocalState: false)
        }

        let cloudWorkspaceIDs = Set(changes.workspaces.map(\.id))
        let cloudServerIDs = Set(changes.servers.map(\.id))
        let missingCandidates = Self.backfillCandidates(
            localWorkspaces: workspaces,
            localServers: servers,
            cloudWorkspaceIDs: cloudWorkspaceIDs,
            cloudServerIDs: cloudServerIDs,
            transientBootstrapWorkspaceID: transientBootstrapWorkspaceID
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
            do {
                try await cloudKit.saveWorkspace(workspace)
                uploadedWorkspaces.append(workspace)
            } catch {
                logger.warning("Failed to backfill workspace \(workspace.name): \(error.localizedDescription)")
            }
        }

        var knownWorkspaceIDs = cloudWorkspaceIDs
        knownWorkspaceIDs.formUnion(uploadedWorkspaces.map(\.id))

        var uploadedServers: [Server] = []
        for server in missingServers {
            guard knownWorkspaceIDs.contains(server.workspaceId) else {
                logger.warning("Skipping server backfill for \(server.name) because workspace \(server.workspaceId) is unavailable in CloudKit")
                continue
            }

            do {
                try await cloudKit.saveServer(server)
                uploadedServers.append(server)
            } catch {
                logger.warning("Failed to backfill server \(server.name): \(error.localizedDescription)")
            }
        }

        let backfillCompleted = uploadedWorkspaces.count == missingWorkspaces.count &&
            uploadedServers.count == missingServers.count

        return FullFetchBackfillResult(
            changes: CloudKitChanges(
                servers: changes.servers + uploadedServers,
                workspaces: changes.workspaces + uploadedWorkspaces,
                deletedServerIDs: changes.deletedServerIDs,
                deletedWorkspaceIDs: changes.deletedWorkspaceIDs,
                isFullFetch: changes.isFullFetch
            ),
            canReplaceLocalState: backfillCompleted
        )
    }

    private var localCacheContainsUserData: Bool {
        if !servers.isEmpty {
            return true
        }

        let effectiveWorkspaces = workspaces.filter { $0.id != transientBootstrapWorkspaceID }

        guard !effectiveWorkspaces.isEmpty else {
            return false
        }

        if effectiveWorkspaces.count > 1 {
            return true
        }

        guard let workspace = effectiveWorkspaces.first else {
            return false
        }

        return !isCanonicalDefaultWorkspace(workspace)
    }

    private var shouldForceCloudKitFullFetchForBootstrap: Bool {
        pendingBootstrapWorkspaceID != nil
    }

    private func isCanonicalDefaultWorkspace(_ workspace: Workspace) -> Bool {
        Self.isCanonicalDefaultWorkspaceCandidate(workspace)
    }

    private func createDefaultWorkspace() -> Workspace {
        Workspace(
            name: AppLanguage.localizedString("My Servers"),
            colorHex: "#007AFF",
            order: 0
        )
    }

    static func shouldCreateBootstrapWorkspace(
        didBootstrapDefaultWorkspace: Bool,
        hasSeenWelcome: Bool,
        hasLocalWorkspaces: Bool
    ) -> Bool {
        !(didBootstrapDefaultWorkspace || hasSeenWelcome) && !hasLocalWorkspaces
    }

    static func isCanonicalDefaultWorkspaceCandidate(_ workspace: Workspace) -> Bool {
        AppLanguage.localizedValues(for: "My Servers").contains(workspace.name) &&
            workspace.colorHex == "#007AFF" &&
            workspace.icon == nil &&
            workspace.order == 0 &&
            workspace.environments == ServerEnvironment.builtInEnvironments &&
            workspace.lastSelectedEnvironmentId == nil &&
            workspace.lastSelectedServerId == nil
    }

    static func backfillCandidates(
        localWorkspaces: [Workspace],
        localServers: [Server],
        cloudWorkspaceIDs: Set<UUID>,
        cloudServerIDs: Set<UUID>,
        transientBootstrapWorkspaceID: UUID?
    ) -> (workspaces: [Workspace], servers: [Server]) {
        let missingWorkspaces = localWorkspaces.filter {
            !cloudWorkspaceIDs.contains($0.id) && $0.id != transientBootstrapWorkspaceID
        }

        let missingWorkspaceIDs = Set(missingWorkspaces.map(\.id))
        let missingServers = localServers.filter {
            !cloudServerIDs.contains($0.id) &&
                $0.workspaceId != transientBootstrapWorkspaceID &&
                (cloudWorkspaceIDs.contains($0.workspaceId) || missingWorkspaceIDs.contains($0.workspaceId))
        }

        return (missingWorkspaces, missingServers)
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

    private func makeWorkspaceMap(from workspaces: [Workspace]) -> [UUID: Workspace] {
        Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
    }

    private func makeServerMap(from servers: [Server]) -> [UUID: Server] {
        Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
    }

    private func removeKnownHostIfUnused(for server: Server, excluding deletedServerIDs: Set<UUID> = []) {
        let isStillUsed = servers.contains {
            !deletedServerIDs.contains($0.id)
                && $0.id != server.id
                && $0.host == server.host
                && $0.port == server.port
        }
        guard !isStillUsed else { return }
        KnownHostsManager.shared.remove(host: server.host, port: server.port)
    }

    private func sortedWorkspaces(from workspaceMap: [UUID: Workspace]) -> [Workspace] {
        Array(workspaceMap.values).sorted { $0.order < $1.order }
    }

    private func sortedServers(from serverMap: [UUID: Server]) -> [Server] {
        Array(serverMap.values).sorted { $0.name < $1.name }
    }

    private func applyCloudKitChanges(_ changes: CloudKitChanges, canReplaceLocalState: Bool = true) {
        if changes.isFullFetch && canReplaceLocalState {
            applyFullFetchCloudKitChanges(changes)
            return
        }

        applyIncrementalCloudKitChanges(changes)
    }

    private func applyFullFetchCloudKitChanges(_ changes: CloudKitChanges) {
        workspaces = dedupedWorkspaces(from: changes.workspaces)
        servers = dedupedServers(from: changes.servers)
    }

    private func applyIncrementalCloudKitChanges(_ changes: CloudKitChanges) {
        if !changes.workspaces.isEmpty {
            upsertWorkspaces(changes.workspaces)
        }
        if !changes.deletedWorkspaceIDs.isEmpty {
            removeWorkspaces(withIDs: changes.deletedWorkspaceIDs)
        }
        if !changes.servers.isEmpty {
            upsertServers(changes.servers)
        }
        if !changes.deletedServerIDs.isEmpty {
            removeServers(withIDs: changes.deletedServerIDs)
        }
    }

    private func dedupedWorkspaces(from updates: [Workspace]) -> [Workspace] {
        var workspaceMap: [UUID: Workspace] = [:]
        for workspace in updates {
            workspaceMap[workspace.id] = workspace
            logger.info("Workspace from CloudKit: \(workspace.name) (id: \(workspace.id))")
        }
        return sortedWorkspaces(from: workspaceMap)
    }

    private func dedupedServers(from updates: [Server]) -> [Server] {
        var serverMap: [UUID: Server] = [:]
        for server in updates {
            serverMap[server.id] = server
            logger.info("Server from CloudKit: \(server.name) (id: \(server.id), workspaceId: \(server.workspaceId))")
        }
        return sortedServers(from: serverMap)
    }

    private func upsertWorkspaces(_ updates: [Workspace]) {
        var workspaceMap = makeWorkspaceMap(from: workspaces)
        for workspace in updates {
            workspaceMap[workspace.id] = workspace
            logger.info("Workspace updated from CloudKit: \(workspace.name) (id: \(workspace.id))")
        }
        workspaces = sortedWorkspaces(from: workspaceMap)
    }

    private func upsertServers(_ updates: [Server]) {
        var serverMap = makeServerMap(from: servers)
        for server in updates {
            serverMap[server.id] = server
            logger.info("Server updated from CloudKit: \(server.name) (id: \(server.id), workspaceId: \(server.workspaceId))")
        }
        servers = sortedServers(from: serverMap)
    }

    private func removeWorkspaces(withIDs ids: [UUID]) {
        let idSet = Set(ids)
        workspaces.removeAll { idSet.contains($0.id) }
    }

    private func removeServers(withIDs ids: [UUID]) {
        let idSet = Set(ids)
        let removedServers = servers.filter { idSet.contains($0.id) }
        for server in removedServers {
            removeKnownHostIfUnused(for: server, excluding: idSet)
        }
        servers.removeAll { idSet.contains($0.id) }
    }

    /// Repairs servers that reference non-existent workspaces by reassigning them to the first available workspace
    private func repairOrphanedServers() async {
        let workspaceIds = Set(workspaces.map { $0.id })
        let orphanedServers = servers.filter { !workspaceIds.contains($0.workspaceId) }

        guard !orphanedServers.isEmpty else { return }

        if workspaces.isEmpty {
            let repairWorkspace = Self.workspaceForOrphanRepair(
                existingWorkspaces: workspaces,
                servers: servers,
                fallbackWorkspace: createDefaultWorkspace()
            )
            guard let repairWorkspace else { return }

            workspaces = [repairWorkspace]
            if isSyncEnabled {
                enqueuePendingWorkspaceUpsert(repairWorkspace)
            }
            logger.warning("Created repair workspace '\(repairWorkspace.name)' to recover orphaned servers")
        }

        logger.warning("Found \(orphanedServers.count) ORPHANED servers (workspaceId doesn't match any workspace):")
        for server in orphanedServers {
            logger.warning("  - \(server.name) (id: \(server.id)) references missing workspaceId: \(server.workspaceId)")
        }

        // Auto-repair: reassign orphaned servers to first workspace
        let defaultWorkspace = workspaces[0]
        logger.info("Auto-repairing: reassigning orphaned servers to workspace '\(defaultWorkspace.name)'")
        for i in servers.indices {
            if !workspaceIds.contains(servers[i].workspaceId) {
                let oldWorkspaceId = servers[i].workspaceId
                servers[i] = Server(
                    id: servers[i].id,
                    workspaceId: defaultWorkspace.id,
                    environment: servers[i].environment,
                    name: servers[i].name,
                    host: servers[i].host,
                    port: servers[i].port,
                    eternalTerminalPort: servers[i].eternalTerminalPort,
                    username: servers[i].username,
                    connectionMode: servers[i].connectionMode,
                    authMethod: servers[i].authMethod,
                    cloudflareAccessMode: servers[i].cloudflareAccessMode,
                    cloudflareTeamDomainOverride: servers[i].cloudflareTeamDomainOverride,
                    cloudflareAppDomainOverride: servers[i].cloudflareAppDomainOverride,
                    tags: servers[i].tags,
                    notes: servers[i].notes,
                    lastConnected: servers[i].lastConnected,
                    isFavorite: servers[i].isFavorite,
                    requiresBiometricUnlock: servers[i].requiresBiometricUnlock,
                    tmuxEnabledOverride: servers[i].tmuxEnabledOverride,
                    tmuxStartupBehaviorOverride: servers[i].tmuxStartupBehaviorOverride,
                    createdAt: servers[i].createdAt,
                    updatedAt: Date()
                )
                logger.info("Reassigned server '\(self.servers[i].name)' from \(oldWorkspaceId) to \(defaultWorkspace.id)")

                if isSyncEnabled {
                    enqueuePendingServerUpsert(servers[i])
                }
            }
        }
    }

    /// Push local data to CloudKit to auto-create schema in development mode
    private func initializeCloudKitSchema() async {
        logger.info("Attempting to initialize CloudKit schema by pushing local data...")

        // Push workspaces first
        for workspace in workspaces {
            do {
                if isSyncEnabled {
                    try await cloudKit.saveWorkspace(workspace)
                }
                logger.info("Pushed workspace to CloudKit: \(workspace.name)")
            } catch {
                logger.error("Failed to push workspace \(workspace.name): \(error.localizedDescription)")
            }
        }

        // Push servers
        for server in servers {
            do {
                if isSyncEnabled {
                    try await cloudKit.saveServer(server)
                }
                logger.info("Pushed server to CloudKit: \(server.name)")
            } catch {
                logger.error("Failed to push server \(server.name): \(error.localizedDescription)")
            }
        }

        logger.info("CloudKit schema initialization complete")
    }

    // MARK: - Server CRUD

    func validate(_ mutation: ServerMutation, hasProAccess: Bool) throws {
        switch mutation {
        case .create:
            guard canAddServer(hasProAccess: hasProAccess) else {
                throw VVTermError.proRequired(String(localized: "Upgrade to Pro for unlimited servers"))
            }
        case .update(let server):
            _ = try Self.existingServerIndex(for: server.id, in: servers)
        }
    }

    func apply(_ mutation: ServerMutation) async throws -> Server {
        switch mutation {
        case .create(let server):
            let newServer = Self.serverForInsertion(server)
            promotePendingBootstrapWorkspaceIfNeeded(for: newServer.workspaceId, reason: "adding a server")
            servers.append(newServer)
            enqueuePendingServerUpsert(newServer)
            await persistLocalMutations(logMessage: "Added server: \(newServer.name)")
            return newServer

        case .update(let server):
            let index = try Self.existingServerIndex(for: server.id, in: servers)
            let updatedServer = Self.serverForUpdate(server)
            servers[index] = updatedServer
            enqueuePendingServerUpsert(updatedServer)
            await persistLocalMutations(logMessage: "Updated server: \(updatedServer.name)")
            return updatedServer
        }
    }

    private static func serverForInsertion(_ server: Server, now: Date = Date()) -> Server {
        Server(
            id: server.id,
            workspaceId: server.workspaceId,
            environment: server.environment,
            name: server.name,
            host: server.host,
            port: server.port,
            eternalTerminalPort: server.eternalTerminalPort,
            username: server.username,
            connectionMode: server.connectionMode,
            authMethod: server.authMethod,
            cloudflareAccessMode: server.cloudflareAccessMode,
            cloudflareTeamDomainOverride: server.cloudflareTeamDomainOverride,
            cloudflareAppDomainOverride: server.cloudflareAppDomainOverride,
            tags: server.tags,
            notes: server.notes,
            requiresBiometricUnlock: server.requiresBiometricUnlock,
            tmuxEnabledOverride: server.tmuxEnabledOverride,
            tmuxStartupBehaviorOverride: server.tmuxStartupBehaviorOverride,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func serverForUpdate(_ server: Server, now: Date = Date()) -> Server {
        Server(
            id: server.id,
            workspaceId: server.workspaceId,
            environment: server.environment,
            name: server.name,
            host: server.host,
            port: server.port,
            eternalTerminalPort: server.eternalTerminalPort,
            username: server.username,
            connectionMode: server.connectionMode,
            authMethod: server.authMethod,
            cloudflareAccessMode: server.cloudflareAccessMode,
            cloudflareTeamDomainOverride: server.cloudflareTeamDomainOverride,
            cloudflareAppDomainOverride: server.cloudflareAppDomainOverride,
            tags: server.tags,
            notes: server.notes,
            lastConnected: server.lastConnected,
            isFavorite: server.isFavorite,
            requiresBiometricUnlock: server.requiresBiometricUnlock,
            tmuxEnabledOverride: server.tmuxEnabledOverride,
            tmuxStartupBehaviorOverride: server.tmuxStartupBehaviorOverride,
            createdAt: server.createdAt,
            updatedAt: now
        )
    }

    func deleteServer(_ server: Server) async throws {
        guard let storedServer = servers.first(where: { $0.id == server.id }) else { return }
        guard await AppLockManager.shared.authorizeProtectedServerAction(
            storedServer,
            action: .delete
        ) else {
            throw VVTermError.authorizationRequired
        }

        try await deleteServerData(storedServer)
    }

    private func deleteServerData(_ server: Server) async throws {
        try keychain.deleteCredentials(for: server.id)

        removeKnownHostIfUnused(for: server)
        servers.removeAll { $0.id == server.id }
        enqueuePendingServerDelete(server)
        await persistLocalMutations(logMessage: "Deleted server: \(server.name)")
    }

    func updateLastConnected(for server: Server) async {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index].lastConnected = Date()
        saveLocalData()
    }

    // MARK: - Workspace CRUD

    func addWorkspace(_ workspace: Workspace, hasProAccess: Bool) async throws {
        guard canAddWorkspace(hasProAccess: hasProAccess) else {
            throw VVTermError.proRequired(String(localized: "Upgrade to Pro for unlimited workspaces"))
        }

        var newWorkspace = workspace
        newWorkspace = Workspace(
            id: workspace.id,
            name: workspace.name,
            colorHex: workspace.colorHex,
            icon: workspace.icon,
            order: workspaces.count,
            createdAt: Date(),
            updatedAt: Date()
        )

        pendingBootstrapWorkspaceID = nil
        workspaces.append(newWorkspace)
        enqueuePendingWorkspaceUpsert(newWorkspace)
        await persistLocalMutations(logMessage: "Added workspace: \(newWorkspace.name)")
    }

    func updateWorkspace(_ workspace: Workspace) async throws {
        let index = try Self.existingWorkspaceIndex(for: workspace.id, in: workspaces)
        var updatedWorkspace = workspace
        updatedWorkspace = Workspace(
            id: workspace.id,
            name: workspace.name,
            colorHex: workspace.colorHex,
            icon: workspace.icon,
            order: workspace.order,
            environments: workspace.environments,
            lastSelectedEnvironmentId: workspace.lastSelectedEnvironmentId,
            lastSelectedServerId: workspace.lastSelectedServerId,
            createdAt: workspace.createdAt,
            updatedAt: Date()
        )

        workspaces[index] = updatedWorkspace
        promotePendingBootstrapWorkspaceIfNeeded(for: updatedWorkspace.id, reason: "updating workspace metadata")
        enqueuePendingWorkspaceUpsert(updatedWorkspace)
        await persistLocalMutations(logMessage: "Updated workspace: \(updatedWorkspace.name)")
    }

    static func existingServerIndex(for id: UUID, in servers: [Server]) throws -> Int {
        guard let index = servers.firstIndex(where: { $0.id == id }) else {
            throw VVTermError.serverNotFound
        }
        return index
    }

    static func existingWorkspaceIndex(for id: UUID, in workspaces: [Workspace]) throws -> Int {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
            throw VVTermError.workspaceNotFound
        }
        return index
    }

    func deleteWorkspace(_ workspace: Workspace) async throws {
        guard let plan = WorkspaceDeletionPlan(
            workspaceID: workspace.id,
            servers: servers,
            workspaces: workspaces
        ) else {
            return
        }

        for server in plan.deletedServers where server.requiresBiometricUnlock {
            guard await AppLockManager.shared.authorizeProtectedServerAction(
                server,
                action: .delete
            ) else {
                throw VVTermError.authorizationRequired
            }
        }

        guard let currentPlan = WorkspaceDeletionPlan(
            workspaceID: workspace.id,
            servers: servers,
            workspaces: workspaces
        ), plan.hasSameDeletionSnapshot(as: currentPlan) else {
            throw VVTermError.workspaceDeletionChanged
        }

        let journal = try workspaceDeletionTransaction.commit(currentPlan)
        applyCommittedWorkspaceDeletion(currentPlan)
        await drainPendingCloudKitMutations()

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
        servers = plan.remainingServers
        workspaces = plan.remainingWorkspaces
        if pendingBootstrapWorkspaceID == plan.workspace.id {
            pendingBootstrapWorkspaceID = nil
        }
    }

    func reorderWorkspaces(from source: IndexSet, to destination: Int) async throws {
        workspaces.moveElements(fromOffsets: source, toOffset: destination)
        pendingBootstrapWorkspaceID = nil

        // Update order for all workspaces
        for (index, workspace) in workspaces.enumerated() {
            var updated = workspace
            updated = Workspace(
                id: workspace.id,
                name: workspace.name,
                colorHex: workspace.colorHex,
                icon: workspace.icon,
                order: index,
                environments: workspace.environments,
                lastSelectedEnvironmentId: workspace.lastSelectedEnvironmentId,
                lastSelectedServerId: workspace.lastSelectedServerId,
                createdAt: workspace.createdAt,
                updatedAt: Date()
            )
            workspaces[index] = updated
            enqueuePendingWorkspaceUpsert(updated)
        }
        await persistLocalMutations(logMessage: "Reordered workspaces")
    }

    // MARK: - Queries

    func servers(in workspace: Workspace, environment: ServerEnvironment?) -> [Server] {
        let workspaceServers = servers.filter { $0.workspaceId == workspace.id }

        guard let environment = environment else {
            return workspaceServers
        }

        return workspaceServers.filter { $0.environment.id == environment.id }
    }

    func recentServers(limit: Int = 5) -> [Server] {
        servers
            .filter { $0.lastConnected != nil }
            .sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    func favoriteServers() -> [Server] {
        servers.filter { $0.isFavorite }
    }

    func searchServers(_ query: String) -> [Server] {
        guard !query.isEmpty else { return servers }
        let lowercased = query.lowercased()
        return servers.filter {
            $0.name.lowercased().contains(lowercased) ||
            $0.host.lowercased().contains(lowercased) ||
            $0.username.lowercased().contains(lowercased) ||
            $0.tags.contains { $0.lowercased().contains(lowercased) }
        }
    }

    func workspace(withId id: UUID?) -> Workspace? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }
    }

    func assignmentWorkspaces(for server: Server?, hasProAccess: Bool) -> [Workspace] {
        if hasProAccess {
            return workspacesSortedByOrder
        }

        guard let server,
              let currentWorkspace = workspace(withId: server.workspaceId) else {
            let unlockedIDs = unlockedWorkspaceIDs(hasProAccess: false)
            return workspacesSortedByOrder.filter { unlockedIDs.contains($0.id) }
        }

        let allowedDestinationIDs = moveDestinationIDs(for: server, hasProAccess: false)
        return workspacesSortedByOrder.filter {
            $0.id == currentWorkspace.id || allowedDestinationIDs.contains($0.id)
        }
    }

    func moveDestinations(for server: Server, hasProAccess: Bool) -> [Workspace] {
        let destinationIDs = moveDestinationIDs(for: server, hasProAccess: hasProAccess)
        return workspacesSortedByOrder.filter { destinationIDs.contains($0.id) }
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

    func canAssignServer(_ server: Server, to destination: Workspace, hasProAccess: Bool) -> Bool {
        if server.workspaceId == destination.id {
            return true
        }
        return moveDestinationIDs(for: server, hasProAccess: hasProAccess).contains(destination.id)
    }

    func moveServer(
        _ server: Server,
        to destination: Workspace,
        preferredEnvironment: ServerEnvironment? = nil,
        hasProAccess: Bool
    ) async throws -> Server {
        guard let refreshedDestination = workspace(withId: destination.id) else {
            throw VVTermError.moveNotAllowed(String(localized: "The destination workspace is no longer available."))
        }

        if let restriction = moveRestriction(
            for: server,
            destination: refreshedDestination,
            hasProAccess: hasProAccess
        ) {
            throw restriction
        }

        let sourceWorkspace = workspace(withId: server.workspaceId)
        let resolvedEnvironment = resolvedEnvironment(
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

    func canAddServer(hasProAccess: Bool) -> Bool {
        if hasProAccess { return true }
        return servers.count < freeServerLimit
    }

    func canAddWorkspace(hasProAccess: Bool) -> Bool {
        if hasProAccess { return true }
        return workspaces.count < FreeTierLimits.maxWorkspaces
    }

    var freeServerLimit: Int {
        freePlanGeneration.serverLimit
    }

    var isLegacyFreePlan: Bool {
        freePlanGeneration == .legacyThreeServers
    }

    // MARK: - Downgrade Locking
    // When user downgrades from Pro, excess servers/workspaces are locked

    /// Returns sorted servers with oldest (by createdAt) first - these get priority access
    private var serversSortedByCreation: [Server] {
        servers.sorted { $0.createdAt < $1.createdAt }
    }

    /// Returns sorted workspaces with oldest (by order, then createdAt) first
    private var workspacesSortedByOrder: [Workspace] {
        workspaces.sorted { $0.order < $1.order }
    }

    /// Set of server IDs that are accessible on free tier (oldest N servers)
    func unlockedServerIDs(hasProAccess: Bool) -> Set<UUID> {
        if hasProAccess { return Set(servers.map(\.id)) }
        let unlocked = serversSortedByCreation.prefix(freeServerLimit)
        return Set(unlocked.map(\.id))
    }

    /// Set of workspace IDs that are accessible on free tier (first N workspaces by order)
    func unlockedWorkspaceIDs(hasProAccess: Bool) -> Set<UUID> {
        if hasProAccess { return Set(workspaces.map(\.id)) }
        let unlocked = workspacesSortedByOrder.prefix(FreeTierLimits.maxWorkspaces)
        return Set(unlocked.map(\.id))
    }

    /// Check if a specific server is locked (over free tier limit)
    func isServerLocked(_ server: Server, hasProAccess: Bool) -> Bool {
        if hasProAccess { return false }
        return !unlockedServerIDs(hasProAccess: false).contains(server.id)
    }

    /// Check if a specific workspace is locked (over free tier limit)
    func isWorkspaceLocked(_ workspace: Workspace, hasProAccess: Bool) -> Bool {
        if hasProAccess { return false }
        return !unlockedWorkspaceIDs(hasProAccess: false).contains(workspace.id)
    }

    /// Number of servers that are locked due to downgrade
    func lockedServersCount(hasProAccess: Bool) -> Int {
        if hasProAccess { return 0 }
        return max(0, servers.count - freeServerLimit)
    }

    /// Number of workspaces that are locked due to downgrade
    func lockedWorkspacesCount(hasProAccess: Bool) -> Int {
        if hasProAccess { return 0 }
        return max(0, workspaces.count - FreeTierLimits.maxWorkspaces)
    }

    /// Whether user has any locked items after downgrade
    func hasLockedItems(hasProAccess: Bool) -> Bool {
        lockedServersCount(hasProAccess: hasProAccess) > 0
            || lockedWorkspacesCount(hasProAccess: hasProAccess) > 0
    }

    private func moveDestinationIDs(for server: Server, hasProAccess: Bool) -> Set<UUID> {
        ServerMoveSupport.allowedDestinationIDs(
            isPro: hasProAccess,
            sourceWorkspaceId: server.workspaceId,
            workspacesInOrder: workspacesSortedByOrder,
            unlockedWorkspaceIds: unlockedWorkspaceIDs(hasProAccess: hasProAccess)
        )
    }

    private func moveRestriction(
        for server: Server,
        destination: Workspace,
        hasProAccess: Bool
    ) -> VVTermError? {
        guard server.workspaceId != destination.id else { return nil }

        if moveDestinationIDs(for: server, hasProAccess: hasProAccess).contains(destination.id) {
            return nil
        }

        if !hasProAccess && isWorkspaceLocked(destination, hasProAccess: false) {
            return VVTermError.proRequired(String(localized: "Upgrade to Pro to move servers into locked workspaces"))
        }

        return VVTermError.moveNotAllowed(String(localized: "This server can't be moved to that workspace right now."))
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

    func createCustomEnvironment(
        name: String,
        color: String,
        hasProAccess: Bool
    ) throws -> ServerEnvironment {
        guard hasProAccess else {
            throw VVTermError.proRequired(String(localized: "Upgrade to Pro for custom environments"))
        }
        return ServerEnvironment(
            id: UUID(),
            name: name,
            shortName: String(name.prefix(4)),
            colorHex: color,
            isBuiltIn: false
        )
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
        guard refreshPendingBootstrapWorkspaceLocalizationIfNeeded() else { return }
        saveLocalData()
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
        let adjustedDestination = boundedDestination - removedBeforeDestination
        insert(contentsOf: movingElements, at: adjustedDestination)
    }
}

// MARK: - Free Tier Limits

enum FreePlanGeneration: String {
    case legacyThreeServers = "legacy_three_servers"
    case currentOneServer = "current_one_server"

    var serverLimit: Int {
        switch self {
        case .legacyThreeServers: return FreeTierLimits.legacyMaxServers
        case .currentOneServer: return FreeTierLimits.currentMaxServers
        }
    }
}

enum FreeTierLimits {
    static let maxWorkspaces = 1
    static let currentMaxServers = 1
    static let legacyMaxServers = 3
    static let maxTabs = 1
    static let maxCustomActions = 3
    static let planGenerationStorageKey = "freePlanGeneration"
    static let currentOneServerPlanCutoff: Date = {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 6
        components.day = 25
        return components.date ?? Date(timeIntervalSince1970: 1_782_345_600)
    }()

    static func serverLimitDescription(_ limit: Int) -> String {
        if limit == 1 {
            return String(localized: "1 server")
        }
        return String(format: String(localized: "%lld servers"), Int64(limit))
    }
}

// MARK: - VVTerm Error

enum VVTermError: LocalizedError {
    case proRequired(String)
    case serverLocked(String)
    case workspaceLocked(String)
    case moveNotAllowed(String)
    case connectionFailed(String)
    case authenticationFailed
    case authorizationRequired
    case serverNotFound
    case workspaceNotFound
    case workspaceDeletionChanged
    case workspaceDeletionRecoveryPending
    case timeout

    var errorDescription: String? {
        switch self {
        case .proRequired(let message): return message
        case .serverLocked(let serverName):
            return String(format: String(localized: "Server '%@' is locked"), serverName)
        case .workspaceLocked(let workspaceName):
            return String(format: String(localized: "Workspace '%@' is locked"), workspaceName)
        case .moveNotAllowed(let message):
            return message
        case .connectionFailed(let message):
            return String(format: String(localized: "Connection failed: %@"), message)
        case .authenticationFailed:
            return String(localized: "Authentication failed")
        case .authorizationRequired:
            return String(localized: "Authorization is required")
        case .serverNotFound:
            return String(localized: "Server no longer exists.")
        case .workspaceNotFound:
            return String(localized: "Workspace no longer exists.")
        case .workspaceDeletionChanged:
            return String(localized: "The workspace changed while deletion was authorized. Review it and try again.")
        case .workspaceDeletionRecoveryPending:
            return String(localized: "The workspace was deleted, but cleanup is still pending and will retry.")
        case .timeout:
            return String(localized: "Connection timed out")
        }
    }

    var isLockedError: Bool {
        switch self {
        case .serverLocked, .workspaceLocked: return true
        default: return false
        }
    }
}
