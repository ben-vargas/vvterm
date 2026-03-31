import Foundation
import CloudKit
import Combine
import SwiftUI
import os.log

// MARK: - Server Manager

enum ServerMoveSupport {
    static func allowedDestinationIDs(
        isPro: Bool,
        sourceWorkspaceId: UUID,
        workspacesInOrder: [Workspace],
        unlockedWorkspaceIds: Set<UUID>
    ) -> Set<UUID> {
        let orderedIDs = workspacesInOrder.map(\.id)

        if isPro {
            return Set(orderedIDs.filter { $0 != sourceWorkspaceId })
        }

        let sourceIsUnlocked = unlockedWorkspaceIds.contains(sourceWorkspaceId)
        if sourceIsUnlocked {
            return Set(orderedIDs.filter { $0 != sourceWorkspaceId && unlockedWorkspaceIds.contains($0) })
        }

        return unlockedWorkspaceIds
    }

    static func resolveEnvironment(
        currentEnvironment: ServerEnvironment,
        preferredEnvironment: ServerEnvironment? = nil,
        destination: Workspace
    ) -> ServerEnvironment {
        if let preferredEnvironment,
           let matchedPreferred = destination.environment(withId: preferredEnvironment.id) {
            return matchedPreferred
        }

        if let matchedCurrent = destination.environment(withId: currentEnvironment.id) {
            return matchedCurrent
        }

        if let production = destination.environment(withId: ServerEnvironment.production.id) {
            return production
        }

        return destination.environments.first ?? .production
    }

    static func requiresEnvironmentFallback(
        currentEnvironment: ServerEnvironment,
        destination: Workspace
    ) -> Bool {
        destination.environment(withId: currentEnvironment.id) == nil
    }
}

@MainActor
final class ServerManager: ObservableObject {
    static let shared = ServerManager()

    @Published var servers: [Server] = []
    @Published var workspaces: [Workspace] = []
    @Published var isLoading = false
    @Published var error: String?

    private let cloudKit = CloudKitManager.shared
    private let syncCoordinator = CloudKitSyncCoordinator.shared
    private let keychain = KeychainManager.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ServerManager")
    private var isSyncEnabled: Bool { SyncSettings.isEnabled }

    // Local storage keys
    private let serversKey = CloudKitSyncConstants.serverStorageKey
    private let workspacesKey = CloudKitSyncConstants.workspaceStorageKey

    private struct FullFetchBackfillResult {
        let changes: CloudKitChanges
        let canReplaceLocalState: Bool
    }

    private init() {
        // Load local data first (fast)
        loadLocalData()
        // Then sync with CloudKit in background
        Task { await loadData() }
    }

    // MARK: - Local Storage

    private func loadLocalData() {
        if let data = UserDefaults.standard.data(forKey: serversKey),
           let decoded = try? JSONDecoder().decode([Server].self, from: data) {
            servers = decoded
            logger.info("Loaded \(decoded.count) servers from local storage")
        }

        if let data = UserDefaults.standard.data(forKey: workspacesKey),
           let decoded = try? JSONDecoder().decode([Workspace].self, from: data) {
            workspaces = decoded
            logger.info("Loaded \(decoded.count) workspaces from local storage")
        }

        // Ensure at least one workspace exists
        if workspaces.isEmpty {
            workspaces = [createDefaultWorkspace()]
            saveLocalData()
        }
    }

    private func saveLocalData() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: serversKey)
        }
        if let data = try? JSONEncoder().encode(workspaces) {
            UserDefaults.standard.set(data, forKey: workspacesKey)
        }
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

        for mutation in snapshot where mutation.entity == .workspace && mutation.operation == .upsert {
            if let workspace = mutation.workspace {
                applyPendingWorkspaceUpsert(workspace)
            }
        }

        for mutation in snapshot where mutation.entity == .server && mutation.operation == .upsert {
            if let server = mutation.server {
                applyPendingServerUpsert(server)
            }
        }

        for mutation in snapshot where mutation.entity == .server && mutation.operation == .delete {
            applyPendingServerDelete(mutation.entityKey)
        }

        for mutation in snapshot where mutation.entity == .workspace && mutation.operation == .delete {
            applyPendingWorkspaceDelete(mutation.entityKey)
        }
    }

    private func reconcilePendingServerAndWorkspaceUpsertsAgainstCloudKit(_ changes: CloudKitChanges) {
        let snapshot = syncCoordinator.snapshot()
        let fetchedServersByID = Dictionary(uniqueKeysWithValues: changes.servers.map { ($0.id, $0) })
        let fetchedWorkspacesByID = Dictionary(uniqueKeysWithValues: changes.workspaces.map { ($0.id, $0) })

        for mutation in snapshot where mutation.operation == .upsert {
            switch mutation.entity {
            case .server:
                guard let pendingServer = mutation.server,
                      let fetchedServer = fetchedServersByID[pendingServer.id] else {
                    continue
                }

                if fetchedServer.updatedAt >= pendingServer.updatedAt {
                    syncCoordinator.removePendingMutation(mutation.id)
                }
            case .workspace:
                guard let pendingWorkspace = mutation.workspace,
                      let fetchedWorkspace = fetchedWorkspacesByID[pendingWorkspace.id] else {
                    continue
                }

                if fetchedWorkspace.updatedAt >= pendingWorkspace.updatedAt {
                    syncCoordinator.removePendingMutation(mutation.id)
                }
            case .terminalTheme, .terminalThemePreference, .terminalAccessoryProfile:
                continue
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

    private func applyPendingServerDelete(_ serverKey: String) {
        guard let serverID = UUID(uuidString: serverKey) else { return }
        servers.removeAll { $0.id == serverID }
    }

    private func applyPendingWorkspaceUpsert(_ workspace: Workspace) {
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }
    }

    private func applyPendingWorkspaceDelete(_ workspaceKey: String) {
        guard let workspaceID = UUID(uuidString: workspaceKey) else { return }
        workspaces.removeAll { $0.id == workspaceID }
        servers.removeAll { $0.workspaceId == workspaceID }
    }

    private func drainPendingCloudKitMutations() async {
        guard isSyncEnabled else { return }
        await syncCoordinator.drainPendingMutations()
    }

    func seedReviewDataIfNeeded() {
        guard servers.isEmpty else { return }

        let workspace: Workspace
        if let firstWorkspace = workspaces.first {
            workspace = firstWorkspace
        } else {
            workspace = Workspace(name: "Review Workspace", colorHex: "#FF9500", order: 0)
            workspaces = [workspace]
        }

        let now = Date()
        servers = [
            Server(
                workspaceId: workspace.id,
                environment: .production,
                name: "Demo - Production",
                host: "example.com",
                username: "demo",
                tags: ["demo", "review"],
                notes: "Demo server for App Review. Replace with your test server if needed.",
                lastConnected: now,
                isFavorite: true
            ),
            Server(
                workspaceId: workspace.id,
                environment: .staging,
                name: "Demo - Staging",
                host: "staging.example.com",
                username: "demo",
                tags: ["demo"],
                notes: "Sample staging entry for App Review."
            ),
            Server(
                workspaceId: workspace.id,
                environment: .development,
                name: "Demo - Development",
                host: "dev.example.com",
                username: "demo",
                tags: ["demo"],
                notes: "Sample development entry for App Review."
            )
        ]

        saveLocalData()
        logger.info("Seeded App Review demo data (\(self.servers.count) servers)")
    }

    /// Clear all local data and re-download from CloudKit
    func clearLocalDataAndResync() async {
        logger.info("Clearing local data and re-syncing from CloudKit...")

        // Clear local storage
        UserDefaults.standard.removeObject(forKey: serversKey)
        UserDefaults.standard.removeObject(forKey: workspacesKey)
        syncCoordinator.clearPendingMutations(for: [.server, .workspace])

        // Clear in-memory data
        servers = []
        workspaces = []
        error = nil

        // Re-fetch from CloudKit
        await loadData()

        logger.info("Clear and re-sync complete: \(self.workspaces.count) workspaces, \(self.servers.count) servers")
    }

    // MARK: - Data Loading

    func loadData() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        guard isSyncEnabled else {
            logger.info("iCloud sync disabled; using local data only")
            return
        }

        do {
            let fetchedChanges = try await cloudKit.fetchChanges()
            let backfillResult = await backfillMissingLocalRecordsIfNeeded(for: fetchedChanges)
            let changes = backfillResult.changes

            // Merge CloudKit data with local (CloudKit wins for conflicts, dedupe by ID)
            logger.info(
                "CloudKit returned \(changes.workspaces.count) workspaces, \(changes.servers.count) servers (full fetch: \(changes.isFullFetch))"
            )

            applyCloudKitChanges(changes, canReplaceLocalState: backfillResult.canReplaceLocalState)
            reconcilePendingServerAndWorkspaceUpsertsAgainstCloudKit(changes)
            applyPendingSyncOverlay()

            // Ensure at least one workspace exists before checking orphans
            if workspaces.isEmpty {
                workspaces = [createDefaultWorkspace()]
                enqueuePendingWorkspaceUpsert(workspaces[0])
                logger.info("Created default workspace: \(self.workspaces[0].name)")
            }

            // Check for and repair orphaned servers (workspaceId doesn't match any workspace)
            await repairOrphanedServers()
            await drainPendingCloudKitMutations()

            // Save merged data locally
            saveLocalData()

            logger.info("Loaded \(self.workspaces.count) workspaces and \(self.servers.count) servers from CloudKit")
        } catch {
            logger.error("Failed to load from CloudKit: \(error.localizedDescription)")
            self.error = error.localizedDescription
            // Local data is already loaded in init, so nothing to do here
            logger.info("Using local data: \(self.workspaces.count) workspaces and \(self.servers.count) servers")

            // Only try to push local data if it's a schema error (record type not found)
            // This auto-creates schema in development mode
            if cloudKit.isAvailable && CloudKitManager.isSchemaError(error) {
                logger.info("Schema error detected, attempting to initialize schema...")
                await initializeCloudKitSchema()
            }
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
        let missingWorkspaces = workspaces.filter { !cloudWorkspaceIDs.contains($0.id) }
        let missingServers = servers.filter { !cloudServerIDs.contains($0.id) }

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

        guard !workspaces.isEmpty else {
            return false
        }

        if workspaces.count > 1 {
            return true
        }

        guard let workspace = workspaces.first else {
            return false
        }

        return !isCanonicalDefaultWorkspace(workspace)
    }

    private func isCanonicalDefaultWorkspace(_ workspace: Workspace) -> Bool {
        workspace.name == String(localized: "My Servers") &&
            workspace.colorHex == "#007AFF" &&
            workspace.icon == nil &&
            workspace.order == 0 &&
            workspace.environments == ServerEnvironment.builtInEnvironments &&
            workspace.lastSelectedEnvironmentId == nil &&
            workspace.lastSelectedServerId == nil
    }

    private func createDefaultWorkspace() -> Workspace {
        Workspace(
            name: String(localized: "My Servers"),
            colorHex: "#007AFF",
            order: 0
        )
    }

    private func applyCloudKitChanges(_ changes: CloudKitChanges, canReplaceLocalState: Bool = true) {
        if changes.isFullFetch && canReplaceLocalState {
            workspaces = dedupedWorkspaces(from: changes.workspaces)
            servers = dedupedServers(from: changes.servers)
            return
        }

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
        return Array(workspaceMap.values).sorted { $0.order < $1.order }
    }

    private func dedupedServers(from updates: [Server]) -> [Server] {
        var serverMap: [UUID: Server] = [:]
        for server in updates {
            serverMap[server.id] = server
            logger.info("Server from CloudKit: \(server.name) (id: \(server.id), workspaceId: \(server.workspaceId))")
        }
        return Array(serverMap.values).sorted { $0.name < $1.name }
    }

    private func upsertWorkspaces(_ updates: [Workspace]) {
        var workspaceMap = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        for workspace in updates {
            workspaceMap[workspace.id] = workspace
            logger.info("Workspace updated from CloudKit: \(workspace.name) (id: \(workspace.id))")
        }
        workspaces = Array(workspaceMap.values).sorted { $0.order < $1.order }
    }

    private func upsertServers(_ updates: [Server]) {
        var serverMap = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        for server in updates {
            serverMap[server.id] = server
            logger.info("Server updated from CloudKit: \(server.name) (id: \(server.id), workspaceId: \(server.workspaceId))")
        }
        servers = Array(serverMap.values).sorted { $0.name < $1.name }
    }

    private func removeWorkspaces(withIDs ids: [UUID]) {
        let idSet = Set(ids)
        workspaces.removeAll { idSet.contains($0.id) }
    }

    private func removeServers(withIDs ids: [UUID]) {
        let idSet = Set(ids)
        servers.removeAll { idSet.contains($0.id) }
    }

    /// Repairs servers that reference non-existent workspaces by reassigning them to the first available workspace
    private func repairOrphanedServers() async {
        let workspaceIds = Set(workspaces.map { $0.id })
        let orphanedServers = servers.filter { !workspaceIds.contains($0.workspaceId) }

        guard !orphanedServers.isEmpty else { return }

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

    func addServer(_ server: Server, credentials: ServerCredentials) async throws {
        guard canAddServer else {
            throw VVTermError.proRequired(String(localized: "Upgrade to Pro for unlimited servers"))
        }

        var newServer = server
        newServer = Server(
            id: server.id,
            workspaceId: server.workspaceId,
            environment: server.environment,
            name: server.name,
            host: server.host,
            port: server.port,
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
            createdAt: Date(),
            updatedAt: Date()
        )

        // Store credentials
        if let password = credentials.password {
            try keychain.storePassword(for: newServer.id, password: password)
        }
        if let sshKey = credentials.sshKey {
            try keychain.storeSSHKey(
                for: newServer.id,
                privateKey: sshKey,
                passphrase: credentials.sshPassphrase,
                publicKey: credentials.publicKey
            )
        }
        if let cloudflareClientID = credentials.cloudflareClientID,
           let cloudflareClientSecret = credentials.cloudflareClientSecret {
            try keychain.storeCloudflareServiceToken(
                for: newServer.id,
                clientID: cloudflareClientID,
                clientSecret: cloudflareClientSecret
            )
        }

        servers.append(newServer)
        enqueuePendingServerUpsert(newServer)
        saveLocalData()
        await drainPendingCloudKitMutations()
        logger.info("Added server: \(newServer.name)")
    }

    func updateServer(_ server: Server) async throws {
        var updatedServer = server
        updatedServer = Server(
            id: server.id,
            workspaceId: server.workspaceId,
            environment: server.environment,
            name: server.name,
            host: server.host,
            port: server.port,
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
            updatedAt: Date()
        )

        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = updatedServer
        }
        enqueuePendingServerUpsert(updatedServer)
        saveLocalData()
        await drainPendingCloudKitMutations()
        logger.info("Updated server: \(updatedServer.name)")
    }

    func deleteServer(_ server: Server) async throws {
        try keychain.deleteCredentials(for: server.id)

        servers.removeAll { $0.id == server.id }
        enqueuePendingServerDelete(server)
        saveLocalData()
        await drainPendingCloudKitMutations()
        logger.info("Deleted server: \(server.name)")
    }

    func updateLastConnected(for server: Server) async {
        var updated = server
        updated = Server(
            id: server.id,
            workspaceId: server.workspaceId,
            environment: server.environment,
            name: server.name,
            host: server.host,
            port: server.port,
            username: server.username,
            connectionMode: server.connectionMode,
            authMethod: server.authMethod,
            cloudflareAccessMode: server.cloudflareAccessMode,
            cloudflareTeamDomainOverride: server.cloudflareTeamDomainOverride,
            cloudflareAppDomainOverride: server.cloudflareAppDomainOverride,
            tags: server.tags,
            notes: server.notes,
            lastConnected: Date(),
            isFavorite: server.isFavorite,
            requiresBiometricUnlock: server.requiresBiometricUnlock,
            tmuxEnabledOverride: server.tmuxEnabledOverride,
            tmuxStartupBehaviorOverride: server.tmuxStartupBehaviorOverride,
            createdAt: server.createdAt,
            updatedAt: Date()
        )

        try? await updateServer(updated)
    }

    // MARK: - Workspace CRUD

    func addWorkspace(_ workspace: Workspace) async throws {
        guard canAddWorkspace else {
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

        workspaces.append(newWorkspace)
        enqueuePendingWorkspaceUpsert(newWorkspace)
        saveLocalData()
        await drainPendingCloudKitMutations()
        logger.info("Added workspace: \(newWorkspace.name)")
    }

    func updateWorkspace(_ workspace: Workspace) async throws {
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

        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = updatedWorkspace
        }
        enqueuePendingWorkspaceUpsert(updatedWorkspace)
        saveLocalData()
        await drainPendingCloudKitMutations()
        logger.info("Updated workspace: \(updatedWorkspace.name)")
    }

    func deleteWorkspace(_ workspace: Workspace) async throws {
        // Delete all servers in workspace
        let workspaceServers = servers.filter { $0.workspaceId == workspace.id }
        for server in workspaceServers {
            try await deleteServer(server)
        }

        workspaces.removeAll { $0.id == workspace.id }
        enqueuePendingWorkspaceDelete(workspace)
        saveLocalData()
        await drainPendingCloudKitMutations()
        logger.info("Deleted workspace: \(workspace.name)")
    }

    func reorderWorkspaces(from source: IndexSet, to destination: Int) async throws {
        workspaces.move(fromOffsets: source, toOffset: destination)

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
        saveLocalData()
        await drainPendingCloudKitMutations()
        logger.info("Reordered workspaces")
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

    func assignmentWorkspaces(for server: Server?) -> [Workspace] {
        if StoreManager.shared.isPro {
            return workspacesSortedByOrder
        }

        guard let server,
              let currentWorkspace = workspace(withId: server.workspaceId) else {
            return workspacesSortedByOrder.filter { unlockedWorkspaceIds.contains($0.id) }
        }

        let allowedDestinationIDs = moveDestinationIDs(for: server)
        return workspacesSortedByOrder.filter {
            $0.id == currentWorkspace.id || allowedDestinationIDs.contains($0.id)
        }
    }

    func moveDestinations(for server: Server) -> [Workspace] {
        let destinationIDs = moveDestinationIDs(for: server)
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

    func canAssignServer(_ server: Server, to destination: Workspace) -> Bool {
        if server.workspaceId == destination.id {
            return true
        }
        return moveDestinationIDs(for: server).contains(destination.id)
    }

    func moveServer(
        _ server: Server,
        to destination: Workspace,
        preferredEnvironment: ServerEnvironment? = nil
    ) async throws -> Server {
        guard let refreshedDestination = workspace(withId: destination.id) else {
            throw VVTermError.moveNotAllowed(String(localized: "The destination workspace is no longer available."))
        }

        if let restriction = moveRestriction(for: server, destination: refreshedDestination) {
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

        try await updateServer(updatedServer)
        try await updateWorkspaceSelectionMetadataAfterMove(
            serverId: server.id,
            from: sourceWorkspace,
            to: refreshedDestination
        )

        return updatedServer
    }

    // MARK: - Pro Limits

    var canAddServer: Bool {
        if StoreManager.shared.isPro { return true }
        return servers.count < FreeTierLimits.maxServers
    }

    var canAddWorkspace: Bool {
        if StoreManager.shared.isPro { return true }
        return workspaces.count < FreeTierLimits.maxWorkspaces
    }

    var canCreateCustomEnvironment: Bool {
        StoreManager.shared.isPro
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
    var unlockedServerIds: Set<UUID> {
        if StoreManager.shared.isPro { return Set(servers.map(\.id)) }
        let unlocked = serversSortedByCreation.prefix(FreeTierLimits.maxServers)
        return Set(unlocked.map(\.id))
    }

    /// Set of workspace IDs that are accessible on free tier (first N workspaces by order)
    var unlockedWorkspaceIds: Set<UUID> {
        if StoreManager.shared.isPro { return Set(workspaces.map(\.id)) }
        let unlocked = workspacesSortedByOrder.prefix(FreeTierLimits.maxWorkspaces)
        return Set(unlocked.map(\.id))
    }

    /// Check if a specific server is locked (over free tier limit)
    func isServerLocked(_ server: Server) -> Bool {
        if StoreManager.shared.isPro { return false }
        return !unlockedServerIds.contains(server.id)
    }

    /// Check if a specific workspace is locked (over free tier limit)
    func isWorkspaceLocked(_ workspace: Workspace) -> Bool {
        if StoreManager.shared.isPro { return false }
        return !unlockedWorkspaceIds.contains(workspace.id)
    }

    /// Number of servers that are locked due to downgrade
    var lockedServersCount: Int {
        if StoreManager.shared.isPro { return 0 }
        return max(0, servers.count - FreeTierLimits.maxServers)
    }

    /// Number of workspaces that are locked due to downgrade
    var lockedWorkspacesCount: Int {
        if StoreManager.shared.isPro { return 0 }
        return max(0, workspaces.count - FreeTierLimits.maxWorkspaces)
    }

    /// Whether user has any locked items after downgrade
    var hasLockedItems: Bool {
        lockedServersCount > 0 || lockedWorkspacesCount > 0
    }

    private func moveDestinationIDs(for server: Server) -> Set<UUID> {
        ServerMoveSupport.allowedDestinationIDs(
            isPro: StoreManager.shared.isPro,
            sourceWorkspaceId: server.workspaceId,
            workspacesInOrder: workspacesSortedByOrder,
            unlockedWorkspaceIds: unlockedWorkspaceIds
        )
    }

    private func moveRestriction(for server: Server, destination: Workspace) -> VVTermError? {
        guard server.workspaceId != destination.id else { return nil }

        if moveDestinationIDs(for: server).contains(destination.id) {
            return nil
        }

        if !StoreManager.shared.isPro && isWorkspaceLocked(destination) {
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

    func createCustomEnvironment(name: String, color: String) throws -> ServerEnvironment {
        guard canCreateCustomEnvironment else {
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
            try await updateServer(updatedServer)
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
            try await updateServer(updatedServer)
        }

        return updatedWorkspace
    }
}

// MARK: - Free Tier Limits

enum FreeTierLimits {
    static let maxWorkspaces = 1
    static let maxServers = 3
    static let maxTabs = 1
}

// MARK: - VVTerm Error

enum VVTermError: LocalizedError {
    case proRequired(String)
    case serverLocked(String)
    case workspaceLocked(String)
    case moveNotAllowed(String)
    case connectionFailed(String)
    case authenticationFailed
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
