import Foundation
import Combine
import os.log

@MainActor
final class RemoteFileBrowserStore: ObservableObject {
    typealias ServerProvider = @MainActor (UUID) -> Server?
    typealias WorkingDirectoryProvider = @MainActor (UUID) -> String?

    enum ToolbarCommandAction: Sendable {
        case upload(destinationPath: String)
        case createFolder(destinationPath: String)
    }

    struct ToolbarCommand: Identifiable, Sendable {
        let id = UUID()
        let serverId: UUID
        let action: ToolbarCommandAction
    }

    struct TransferProgress: Sendable {
        let completedUnitCount: Int
        let totalUnitCount: Int
        let currentItemName: String
    }

    struct LocalUploadPlanItem: Identifiable, Sendable {
        let sourceURL: URL
        let remoteName: String

        var id: String {
            "\(sourceURL.absoluteString)->\(remoteName)"
        }
    }

    struct LocalUploadPlanCandidate: Identifiable, Sendable {
        let sourceURL: URL
        let originalName: String
        let existingEntry: RemoteFileEntry?
        let suggestedName: String?

        var id: String {
            "\(sourceURL.absoluteString)->\(originalName)"
        }

        var hasConflict: Bool {
            existingEntry != nil
        }
    }

    struct BrowserState: Sendable {
        var currentPath: String?
        var entries: [RemoteFileEntry]
        var sort: RemoteFileSort
        var sortDirection: RemoteFileSortDirection
        var showHiddenFiles: Bool
        var hasCustomizedHiddenFiles: Bool
        var hasLoadedDirectory: Bool
        var isLoadingDirectory: Bool
        var isLoadingViewer: Bool
        var isDirectoryTruncated: Bool
        var filesystemStatus: RemoteFileFilesystemStatus?
        var error: RemoteFileBrowserError?
        var viewerError: RemoteFileBrowserError?
        var viewerPayload: RemoteFileViewerPayload?
        var selectedEntryPath: String?

        init(persisted: RemoteFileBrowserPersistedState) {
            currentPath = persisted.lastVisitedPath.map { RemoteFilePath.normalize($0) }
            entries = []
            sort = persisted.sort
            sortDirection = persisted.sortDirection
            showHiddenFiles = persisted.showHiddenFiles
            hasCustomizedHiddenFiles = persisted.hasCustomizedHiddenFiles
            hasLoadedDirectory = false
            isLoadingDirectory = false
            isLoadingViewer = false
            isDirectoryTruncated = false
            filesystemStatus = nil
            error = nil
            viewerError = nil
            viewerPayload = nil
            selectedEntryPath = nil
        }

        var breadcrumbs: [RemoteFileBreadcrumb] {
            guard let currentPath else { return [] }
            return RemoteFilePath.breadcrumbs(for: currentPath)
        }
    }

    struct DirectorySnapshot: Sendable {
        let path: String
        let entries: [RemoteFileEntry]
        let isTruncated: Bool
        let filesystemStatus: RemoteFileFilesystemStatus?
    }

    @Published private(set) var states: [UUID: BrowserState] = [:]
    @Published var pendingToolbarCommand: ToolbarCommand?

    let defaults: UserDefaults
    let persistenceKey = "remoteFileBrowserState.v1"
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "RemoteFiles")
    let remoteFileServiceAdapter: SSHSFTPAdapter
    let temporaryStorage: RemoteFileTemporaryStorage
    let previewLoader: RemoteFilePreviewLoader
    let conflictResolver: RemoteFileConflictResolver
    let serverProvider: ServerProvider
    let workingDirectoryProvider: WorkingDirectoryProvider

    var persistedStates: [String: RemoteFileBrowserPersistedState] = [:]
    var directoryRequestIDs: [UUID: UUID] = [:]
    var viewerRequestIDs: [UUID: UUID] = [:]

    static let directoryEntryLimit = 2_000
    static let defaultPreviewBytes = 512 * 1_024
    static let hardPreviewBytes = 2 * 1_024 * 1_024
    static let previewConfirmationBytes = 1 * 1_024 * 1_024
    static let maxMediaPreviewBytes = 64 * 1_024 * 1_024

    init(
        defaults: UserDefaults = .standard,
        remoteFileServiceAdapter: SSHSFTPAdapter? = nil,
        temporaryStorage: RemoteFileTemporaryStorage = RemoteFileTemporaryStorage(),
        previewLoader: RemoteFilePreviewLoader = RemoteFilePreviewLoader(),
        conflictResolver: RemoteFileConflictResolver = RemoteFileConflictResolver(),
        serverProvider: @escaping ServerProvider = { serverId in
            ServerManager.shared.servers.first { $0.id == serverId }
        },
        workingDirectoryProvider: @escaping WorkingDirectoryProvider = { serverId in
            if let selectedSessionId = ConnectionSessionManager.shared.selectedSessionByServer[serverId],
               let path = ConnectionSessionManager.shared.workingDirectory(for: selectedSessionId) {
                return path
            }

            if let anySession = ConnectionSessionManager.shared.sessions.first(where: { $0.serverId == serverId }),
               let path = ConnectionSessionManager.shared.workingDirectory(for: anySession.id) {
                return path
            }

            if let selectedTab = TerminalTabManager.shared.selectedTab(for: serverId),
               let path = TerminalTabManager.shared.workingDirectory(for: selectedTab.focusedPaneId) {
                return path
            }

            if let anyPane = TerminalTabManager.shared.paneStates.values.first(where: { $0.serverId == serverId }),
               let path = TerminalTabManager.shared.workingDirectory(for: anyPane.paneId) {
                return path
            }

            return nil
        }
    ) {
        self.defaults = defaults
        self.remoteFileServiceAdapter = remoteFileServiceAdapter ?? SSHSFTPAdapter()
        self.temporaryStorage = temporaryStorage
        self.previewLoader = previewLoader
        self.conflictResolver = conflictResolver
        self.serverProvider = serverProvider
        self.workingDirectoryProvider = workingDirectoryProvider
        loadPersistedStates()
    }

    func state(for serverId: UUID) -> BrowserState {
        states[serverId] ?? BrowserState(persisted: persistedState(for: serverId))
    }

    func currentPath(for serverId: UUID) -> String {
        state(for: serverId).currentPath ?? "/"
    }

    func displayedEntries(for serverId: UUID) -> [RemoteFileEntry] {
        let state = state(for: serverId)
        let visibleEntries = state.showHiddenFiles
            ? state.entries
            : state.entries.filter { !$0.isHidden }
        return visibleEntries.sortedForBrowser(using: state.sort, direction: state.sortDirection)
    }

    func entries(for serverId: UUID) -> [RemoteFileEntry] {
        displayedEntries(for: serverId)
    }

    func selectedEntryPath(for serverId: UUID) -> String? {
        state(for: serverId).selectedEntryPath
    }

    func viewerPayload(for serverId: UUID) -> RemoteFileViewerPayload? {
        state(for: serverId).viewerPayload
    }

    func error(for serverId: UUID) -> RemoteFileBrowserError? {
        state(for: serverId).error
    }

    func viewerError(for serverId: UUID) -> RemoteFileBrowserError? {
        state(for: serverId).viewerError
    }

    func isLoading(for serverId: UUID) -> Bool {
        state(for: serverId).isLoadingDirectory
    }

    func isLoadingViewer(for serverId: UUID) -> Bool {
        state(for: serverId).isLoadingViewer
    }

    func isTruncated(for serverId: UUID) -> Bool {
        state(for: serverId).isDirectoryTruncated
    }

    func filesystemStatus(for serverId: UUID) -> RemoteFileFilesystemStatus? {
        state(for: serverId).filesystemStatus
    }

    func sort(for serverId: UUID) -> RemoteFileSort {
        state(for: serverId).sort
    }

    func sortDirection(for serverId: UUID) -> RemoteFileSortDirection {
        state(for: serverId).sortDirection
    }

    func showHiddenFiles(for serverId: UUID) -> Bool {
        state(for: serverId).showHiddenFiles
    }

    func breadcrumbs(for serverId: UUID) -> [RemoteFileBreadcrumb] {
        state(for: serverId).breadcrumbs
    }

    func loadInitialPath(for server: Server, initialPath: String? = nil) async {
        let currentState = state(for: server.id)
        guard !currentState.isLoadingDirectory else { return }
        guard !currentState.hasLoadedDirectory else { return }

        let requestID = UUID()
        directoryRequestIDs[server.id] = requestID

        updateState(for: server.id) { state in
            state.isLoadingDirectory = true
            state.error = nil
        }

        do {
            let snapshot = try await resolveInitialDirectorySnapshot(for: server, initialPath: initialPath)
            guard directoryRequestIDs[server.id] == requestID else { return }
            applyDirectorySnapshot(snapshot, for: server.id)
        } catch {
            guard directoryRequestIDs[server.id] == requestID else { return }
            logger.error("Initial file browser load failed for \(server.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            updateState(for: server.id) { state in
                state.isLoadingDirectory = false
                state.error = RemoteFileBrowserError.map(error)
            }
        }
    }

    func refresh(serverId: UUID) async {
        guard let server = server(for: serverId) else { return }
        let targetPath = state(for: serverId).currentPath
            ?? persistedState(for: serverId).lastVisitedPath
            ?? bestWorkingDirectory(for: serverId)
            ?? "/"
        await loadDirectory(path: targetPath, for: server)
    }

    func refresh(server: Server) async {
        await refresh(serverId: server.id)
    }

    func openBreadcrumb(_ breadcrumb: RemoteFileBreadcrumb, server: Server) async {
        await loadDirectory(path: breadcrumb.path, for: server)
    }

    func openDirectory(_ entry: RemoteFileEntry, serverId: UUID) async {
        guard let server = server(for: serverId) else { return }
        await loadDirectory(path: entry.path, for: server)
    }

    func activate(_ entry: RemoteFileEntry, serverId: UUID) async {
        switch entry.type {
        case .directory:
            await openDirectory(entry, serverId: serverId)
        case .symlink:
            guard let server = server(for: serverId) else { return }
            do {
                let resolvedEntry = try await withRemoteFileService(for: server) { service in
                    try await service.stat(at: entry.path)
                }
                if resolvedEntry.type == .directory {
                    await loadDirectory(path: entry.path, for: server)
                } else {
                    selectFile(entry, serverId: serverId)
                }
            } catch {
                selectFile(entry, serverId: serverId)
            }
        case .file, .other:
            selectFile(entry, serverId: serverId)
        }
    }

    func focus(_ entry: RemoteFileEntry, serverId: UUID) {
        viewerRequestIDs[serverId] = UUID()
        cleanupPreviewArtifact(for: state(for: serverId).viewerPayload)
        updateState(for: serverId) { state in
            state.selectedEntryPath = entry.path
            state.viewerPayload = nil
            state.viewerError = nil
            state.isLoadingViewer = false
        }
    }

    func select(entry: RemoteFileEntry, server: Server) async {
        await activate(entry, serverId: server.id)
    }

    func updateSort(_ sort: RemoteFileSort, serverId: UUID) {
        updateSort(sort, direction: sort.defaultDirection, serverId: serverId)
    }

    func updateSort(_ sort: RemoteFileSort, direction: RemoteFileSortDirection, serverId: UUID) {
        updateState(for: serverId) { state in
            state.sort = sort
            state.sortDirection = direction
        }
        persistState(for: serverId)
    }

    func setShowHiddenFiles(_ showHiddenFiles: Bool, serverId: UUID) {
        updateState(for: serverId) { state in
            state.showHiddenFiles = showHiddenFiles
            state.hasCustomizedHiddenFiles = true
        }
        persistState(for: serverId)
    }

    func disconnect(serverId: UUID) {
        directoryRequestIDs.removeValue(forKey: serverId)
        viewerRequestIDs.removeValue(forKey: serverId)
        temporaryStorage.removePreviewArtifact(for: states[serverId]?.viewerPayload)
        states.removeValue(forKey: serverId)
        remoteFileServiceAdapter.disconnect(serverId: serverId)
    }

    func goUp(serverId: UUID) async {
        guard let server = server(for: serverId) else { return }
        let currentPath = state(for: serverId).currentPath ?? "/"
        let parentPath = RemoteFilePath.parent(of: currentPath)
        guard parentPath != currentPath else { return }
        await loadDirectory(path: parentPath, for: server)
    }

    func goUp(server: Server) async {
        await goUp(serverId: server.id)
    }

    // MARK: - Private

    func loadDirectory(path: String, for server: Server) async {
        let normalizedPath = RemoteFilePath.normalize(path)
        let requestID = UUID()
        directoryRequestIDs[server.id] = requestID
        cleanupPreviewArtifact(for: state(for: server.id).viewerPayload)

        updateState(for: server.id) { state in
            state.isLoadingDirectory = true
            state.error = nil
            state.viewerError = nil
            state.viewerPayload = nil
            state.selectedEntryPath = nil
        }
        viewerRequestIDs.removeValue(forKey: server.id)

        do {
            let snapshot = try await directorySnapshot(path: normalizedPath, for: server)
            guard directoryRequestIDs[server.id] == requestID else { return }
            applyDirectorySnapshot(snapshot, for: server.id)
        } catch {
            guard directoryRequestIDs[server.id] == requestID else { return }
            logger.error("Directory load failed for \(normalizedPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            updateState(for: server.id) { state in
                state.isLoadingDirectory = false
                state.error = RemoteFileBrowserError.map(error)
            }
        }
    }

    func resolveInitialDirectorySnapshot(for server: Server, initialPath: String?) async throws -> DirectorySnapshot {
        let persistedPath = persistedState(for: server.id).lastVisitedPath
        let workingDirectory = bestWorkingDirectory(for: server.id)

        let candidates = [initialPath, persistedPath, workingDirectory]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { RemoteFilePath.normalize($0) }

        for candidate in Array(NSOrderedSet(array: candidates)) {
            guard let path = candidate as? String else { continue }
            do {
                return try await directorySnapshot(path: path, for: server)
            } catch {
                logger.debug("Skipping initial browser path \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        let homePath = try await withRemoteFileService(for: server) { service in
            try await service.resolveHomeDirectory()
        }
        return try await directorySnapshot(path: homePath, for: server)
    }

    private func directorySnapshot(path: String, for server: Server) async throws -> DirectorySnapshot {
        let normalizedPath = RemoteFilePath.normalize(path)
        let entries = try await withRemoteFileService(for: server) { service in
            try await service.listDirectory(at: normalizedPath, maxEntries: Self.directoryEntryLimit)
        }
        let filesystemStatus = try? await withRemoteFileService(for: server) { service in
            try await service.fileSystemStatus(at: normalizedPath)
        }
        return DirectorySnapshot(
            path: normalizedPath,
            entries: entries,
            isTruncated: entries.count >= Self.directoryEntryLimit,
            filesystemStatus: filesystemStatus
        )
    }

    func applyDirectorySnapshot(_ snapshot: DirectorySnapshot, for serverId: UUID) {
        updateState(for: serverId) { state in
            state.currentPath = snapshot.path
            state.entries = snapshot.entries
            state.hasLoadedDirectory = true
            state.isDirectoryTruncated = snapshot.isTruncated
            state.filesystemStatus = snapshot.filesystemStatus
            state.isLoadingDirectory = false
            state.error = nil
        }
        persistState(for: serverId)
    }

    func selectFile(_ entry: RemoteFileEntry, serverId: UUID) {
        focus(entry, serverId: serverId)
    }

    func withRemoteFileService<T>(
        for server: Server,
        operation: @escaping (any RemoteFileService) async throws -> T
    ) async throws -> T {
        try await remoteFileServiceAdapter.withService(for: server, operation: operation)
    }

    func bestWorkingDirectory(for serverId: UUID) -> String? {
        workingDirectoryProvider(serverId)
    }

    func updateState(for serverId: UUID, mutation: (inout BrowserState) -> Void) {
        var state = states[serverId] ?? BrowserState(persisted: persistedState(for: serverId))
        mutation(&state)
        states[serverId] = state
    }

    func server(for serverId: UUID) -> Server? {
        serverProvider(serverId)
    }

    func setPendingToolbarCommand(_ command: ToolbarCommand?) {
        pendingToolbarCommand = command
    }
}

extension String {
    var nonEmptyString: String? {
        isEmpty ? nil : self
    }
}
