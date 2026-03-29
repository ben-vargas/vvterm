import Foundation
import Combine
import os.log

@MainActor
final class RemoteFileBrowserManager: ObservableObject {
    static let shared = RemoteFileBrowserManager()

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

    struct BrowserState: Sendable {
        var currentPath: String?
        var entries: [RemoteFileEntry]
        var sort: RemoteFileSort
        var sortDirection: RemoteFileSortDirection
        var showHiddenFiles: Bool
        var hasCustomizedHiddenFiles: Bool
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

    private enum ClientOwnership: Sendable {
        case borrowed
        case owned
    }

    private struct ClientRegistration: Sendable {
        let client: SSHClient
        let ownership: ClientOwnership
    }

    private struct DirectorySnapshot: Sendable {
        let path: String
        let entries: [RemoteFileEntry]
        let isTruncated: Bool
        let filesystemStatus: RemoteFileFilesystemStatus?
    }

    private struct LocalUploadItemInfo: Sendable {
        let name: String
        let isDirectory: Bool
    }

    private final class TransferProgressTracker {
        private(set) var completedUnitCount = 0
        let totalUnitCount: Int
        let onProgress: (@MainActor @Sendable (TransferProgress) -> Void)?

        init(
            totalUnitCount: Int,
            onProgress: (@MainActor @Sendable (TransferProgress) -> Void)?
        ) {
            self.totalUnitCount = max(1, totalUnitCount)
            self.onProgress = onProgress
        }

        @MainActor
        func advance(currentItemName: String) {
            completedUnitCount += 1
            onProgress?(
                TransferProgress(
                    completedUnitCount: min(completedUnitCount, totalUnitCount),
                    totalUnitCount: totalUnitCount,
                    currentItemName: currentItemName
                )
            )
        }
    }

    @Published private(set) var states: [UUID: BrowserState] = [:]
    @Published private(set) var pendingToolbarCommand: ToolbarCommand?

    private let defaults: UserDefaults
    private let persistenceKey = "remoteFileBrowserState.v1"
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "RemoteFiles")

    private var persistedStates: [String: RemoteFileBrowserPersistedState] = [:]
    private var clients: [UUID: ClientRegistration] = [:]
    private var directoryRequestIDs: [UUID: UUID] = [:]
    private var viewerRequestIDs: [UUID: UUID] = [:]

    private static let directoryEntryLimit = 2_000
    private static let defaultPreviewBytes = 512 * 1_024
    private static let hardPreviewBytes = 2 * 1_024 * 1_024
    static let previewConfirmationBytes = 1 * 1_024 * 1_024
    private static let maxMediaPreviewBytes = 64 * 1_024 * 1_024

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    func requestUploadPicker(for serverId: UUID, destinationPath: String) {
        pendingToolbarCommand = ToolbarCommand(
            serverId: serverId,
            action: .upload(destinationPath: RemoteFilePath.normalize(destinationPath))
        )
    }

    func requestCreateFolder(for serverId: UUID, destinationPath: String) {
        pendingToolbarCommand = ToolbarCommand(
            serverId: serverId,
            action: .createFolder(destinationPath: RemoteFilePath.normalize(destinationPath))
        )
    }

    func consumeToolbarCommand(_ command: ToolbarCommand) {
        guard pendingToolbarCommand?.id == command.id else { return }
        pendingToolbarCommand = nil
    }

    func loadInitialPath(for server: Server, initialPath: String? = nil) async {
        let currentState = state(for: server.id)
        guard !currentState.isLoadingDirectory else { return }

        let normalizedInitialPath = initialPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyString
            .map { RemoteFilePath.normalize($0) }
        if let normalizedInitialPath,
           currentState.currentPath != normalizedInitialPath {
            await loadDirectory(path: normalizedInitialPath, for: server)
            return
        }

        guard currentState.entries.isEmpty else { return }

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

    func openDirectory(_ entry: RemoteFileEntry, serverId: UUID) async {
        guard let server = server(for: serverId) else { return }
        await loadDirectory(path: entry.path, for: server)
    }

    func loadPreview(
        for entry: RemoteFileEntry,
        serverId: UUID,
        allowLargeDownloads: Bool = false
    ) async {
        guard let server = server(for: serverId) else { return }

        let currentState = state(for: serverId)
        if currentState.isLoadingViewer, currentState.selectedEntryPath == entry.path {
            return
        }
        if currentState.viewerPayload?.entry.path == entry.path,
           !(currentState.viewerPayload?.requiresExplicitDownload == true && allowLargeDownloads) {
            return
        }

        if let fileSize = entry.size,
           fileSize > UInt64(Self.previewConfirmationBytes),
           !allowLargeDownloads {
            cleanupPreviewArtifact(for: currentState.viewerPayload)
            viewerRequestIDs.removeValue(forKey: serverId)
            updateState(for: serverId) { state in
                state.selectedEntryPath = entry.path
                state.isLoadingViewer = false
                state.viewerError = nil
                state.viewerPayload = RemoteFileViewerPayload(
                    previewKind: .unavailable,
                    entry: entry,
                    textPreview: nil,
                    previewFileURL: nil,
                    isTruncated: false,
                    unavailableMessage: String(
                        localized: "This file is larger than 1 MB. Download it first if you want to preview it."
                    ),
                    requiresExplicitDownload: true,
                    previewByteCount: fileSize
                )
            }
            return
        }

        let requestID = UUID()
        viewerRequestIDs[serverId] = requestID
        cleanupPreviewArtifact(for: currentState.viewerPayload)

        updateState(for: serverId) { state in
            state.selectedEntryPath = entry.path
            state.isLoadingViewer = true
            state.viewerError = nil
            state.viewerPayload = nil
        }

        do {
            let readLimit = min(Int(entry.size ?? UInt64(Self.defaultPreviewBytes)), Self.hardPreviewBytes)
            let effectiveReadLimit = max(Self.defaultPreviewBytes, readLimit)
            let data = try await withClient(for: server) { client in
                try await client.readFile(at: entry.path, maxBytes: effectiveReadLimit)
            }

            guard viewerRequestIDs[serverId] == requestID else { return }

            let previewData = data.prefix(Self.defaultPreviewBytes)
            let isTruncated = (entry.size.map { $0 > UInt64(Self.defaultPreviewBytes) } ?? false)
                || data.count > Self.defaultPreviewBytes
                || data.count >= Self.hardPreviewBytes
            let previewKind = RemoteFilePreviewDetector.previewKind(for: entry, data: previewData)
            let payload: RemoteFileViewerPayload

            switch previewKind {
            case .text:
                payload = RemoteFileViewerPayload(
                    previewKind: .text,
                    entry: entry,
                    textPreview: RemoteFilePreviewDetector.decodeTextPreview(from: previewData),
                    previewFileURL: nil,
                    isTruncated: isTruncated,
                    unavailableMessage: nil,
                    requiresExplicitDownload: false,
                    previewByteCount: entry.size
                )
            case .image, .video:
                let previewFileURL: URL?
                let unavailableMessage: String?

                if let fileSize = entry.size, fileSize > UInt64(Self.maxMediaPreviewBytes) {
                    previewFileURL = nil
                    unavailableMessage = String(
                        localized: "This file is too large to preview inline. Download it to inspect the full contents."
                    )
                } else {
                    let tempURL = try makePreviewFileURL(for: entry)
                    do {
                        try await withClient(for: server) { client in
                            try await client.downloadFile(at: entry.path, to: tempURL)
                        }
                        previewFileURL = tempURL
                        unavailableMessage = nil
                    } catch {
                        try? FileManager.default.removeItem(at: tempURL)
                        throw error
                    }
                }

                payload = RemoteFileViewerPayload(
                    previewKind: previewFileURL == nil ? .unavailable : previewKind,
                    entry: entry,
                    textPreview: nil,
                    previewFileURL: previewFileURL,
                    isTruncated: false,
                    unavailableMessage: unavailableMessage,
                    requiresExplicitDownload: false,
                    previewByteCount: entry.size
                )
            case .unavailable:
                payload = RemoteFileViewerPayload(
                    previewKind: .unavailable,
                    entry: entry,
                    textPreview: nil,
                    previewFileURL: nil,
                    isTruncated: false,
                    unavailableMessage: String(localized: "Inline preview is unavailable for this file."),
                    requiresExplicitDownload: false,
                    previewByteCount: entry.size
                )
            }

            updateState(for: serverId) { state in
                state.isLoadingViewer = false
                state.viewerError = nil
                state.viewerPayload = payload
            }
        } catch {
            guard viewerRequestIDs[serverId] == requestID else { return }
            logger.error("Remote file preview failed for \(entry.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            updateState(for: serverId) { state in
                state.isLoadingViewer = false
                state.viewerPayload = nil
                state.viewerError = RemoteFileBrowserError.map(error)
            }
        }
    }

    func activate(_ entry: RemoteFileEntry, serverId: UUID) async {
        switch entry.type {
        case .directory:
            await openDirectory(entry, serverId: serverId)
        case .symlink:
            guard let server = server(for: serverId) else { return }
            do {
                let resolvedEntry = try await withClient(for: server) { client in
                    try await client.stat(at: entry.path)
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

    func select(entry: RemoteFileEntry, server: Server) async {
        await activate(entry, serverId: server.id)
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

    func openBreadcrumb(_ breadcrumb: RemoteFileBreadcrumb, server: Server) async {
        await loadDirectory(path: breadcrumb.path, for: server)
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

    func upload(
        data: Data,
        to remotePath: String,
        serverId: UUID,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        try await performMutation(serverId: serverId) { client in
            try await client.upload(
                data,
                to: remotePath,
                permissions: permissions,
                strategy: strategy
            )
        }
    }

    func upload(
        fileAt localURL: URL,
        to remoteDirectoryPath: String,
        serverId: UUID,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        let remotePath = RemoteFilePath.appending(localURL.lastPathComponent, to: remoteDirectoryPath)
        let data = try await loadLocalFileData(from: localURL)
        try await upload(
            data: data,
            to: remotePath,
            serverId: serverId,
            permissions: permissions,
            strategy: strategy
        )
    }

    func createDirectory(
        at remotePath: String,
        serverId: UUID,
        permissions: Int32 = 0o755
    ) async throws {
        try await performMutation(serverId: serverId) { client in
            try await client.createDirectory(at: remotePath, permissions: permissions)
        }
    }

    func createDirectory(
        named directoryName: String,
        in remoteDirectoryPath: String,
        serverId: UUID,
        permissions: Int32 = 0o755
    ) async throws {
        let remotePath = RemoteFilePath.appending(
            try validatedRemoteName(directoryName),
            to: remoteDirectoryPath
        )
        try await createDirectory(at: remotePath, serverId: serverId, permissions: permissions)
    }

    func renameItem(
        at sourcePath: String,
        to destinationPath: String,
        serverId: UUID
    ) async throws {
        try await performMutation(serverId: serverId) { client in
            try await client.renameItem(at: sourcePath, to: destinationPath)
        }
    }

    func deleteFile(at remotePath: String, serverId: UUID) async throws {
        try await performMutation(serverId: serverId) { client in
            try await client.deleteFile(at: remotePath)
        }
    }

    func deleteDirectory(at remotePath: String, serverId: UUID) async throws {
        try await performMutation(serverId: serverId) { client in
            try await client.deleteDirectory(at: remotePath)
        }
    }

    func deleteItem(
        at remotePath: String,
        serverId: UUID,
        type: RemoteFileType? = nil
    ) async throws {
        switch type {
        case .directory:
            try await deleteDirectory(at: remotePath, serverId: serverId)
        case .file, .symlink, .other, nil:
            try await deleteFile(at: remotePath, serverId: serverId)
        }
    }

    func clearViewer(serverId: UUID) {
        cleanupPreviewArtifact(for: state(for: serverId).viewerPayload)
        updateState(for: serverId) { state in
            state.selectedEntryPath = nil
            state.viewerPayload = nil
            state.viewerError = nil
            state.isLoadingViewer = false
        }
        viewerRequestIDs.removeValue(forKey: serverId)
    }

    func setPermissions(_ entry: RemoteFileEntry, permissions: UInt32, serverId: UUID) async throws {
        guard let server = server(for: serverId) else {
            throw RemoteFileBrowserError.disconnected
        }

        let updatedEntry = try await withClient(for: server) { client in
            try await client.setPermissions(at: entry.path, permissions: permissions)
            return try await client.lstat(at: entry.path)
        }

        updateState(for: serverId) { state in
            if let index = state.entries.firstIndex(where: { $0.path == entry.path }) {
                state.entries[index] = updatedEntry
            }

            if state.selectedEntryPath == entry.path,
               let payload = state.viewerPayload,
               payload.entry.path == entry.path {
                state.viewerPayload = RemoteFileViewerPayload(
                    previewKind: payload.previewKind,
                    entry: updatedEntry,
                    textPreview: payload.textPreview,
                    previewFileURL: payload.previewFileURL,
                    isTruncated: payload.isTruncated,
                    unavailableMessage: payload.unavailableMessage,
                    requiresExplicitDownload: payload.requiresExplicitDownload,
                    previewByteCount: payload.previewByteCount
                )
            }
        }
    }

    func saveTextPreview(_ text: String, for entry: RemoteFileEntry, serverId: UUID) async throws {
        guard let server = server(for: serverId) else {
            throw RemoteFileBrowserError.disconnected
        }

        guard let data = text.data(using: .utf8) else {
            throw RemoteFileBrowserError.unsupportedEncoding
        }

        let updatedEntry = try await withClient(for: server) { client in
            let effectivePermissions = Int32(entry.permissions ?? 0o644)
            try await client.upload(data, to: entry.path, permissions: effectivePermissions)
            return try await client.lstat(at: entry.path)
        }

        updateState(for: serverId) { state in
            if let index = state.entries.firstIndex(where: { $0.path == entry.path }) {
                state.entries[index] = updatedEntry
            }

            if state.selectedEntryPath == entry.path {
                state.viewerPayload = RemoteFileViewerPayload(
                    previewKind: .text,
                    entry: updatedEntry,
                    textPreview: text,
                    previewFileURL: nil,
                    isTruncated: false,
                    unavailableMessage: nil,
                    requiresExplicitDownload: false,
                    previewByteCount: UInt64(data.count)
                )
                state.viewerError = nil
            }
        }
    }

    func uploadFiles(
        at urls: [URL],
        to directoryPath: String,
        serverId: UUID,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        guard let server = server(for: serverId) else {
            throw RemoteFileBrowserError.disconnected
        }

        let destinationDirectory = RemoteFilePath.normalize(directoryPath)
        try await withSecurityScopedAccess(to: urls) {
            let progressTracker = TransferProgressTracker(
                totalUnitCount: try await countLocalTransferUnits(at: urls),
                onProgress: onProgress
            )
            try await withClient(for: server) { client in
                for url in urls {
                    try await self.uploadItem(
                        at: url,
                        to: destinationDirectory,
                        using: client,
                        progressTracker: progressTracker
                    )
                }
            }
        }

        clearViewer(serverId: serverId)
        await refresh(serverId: serverId)
    }

    func copyEntries(
        _ entries: [RemoteFileEntry],
        from sourceServerId: UUID,
        to destinationDirectoryPath: String,
        destinationServerId: UUID,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        guard let sourceServer = server(for: sourceServerId),
              let destinationServer = server(for: destinationServerId) else {
            throw RemoteFileBrowserError.disconnected
        }

        let uniqueEntries = uniqueTransferEntries(entries)
        guard !uniqueEntries.isEmpty else { return }

        let destinationDirectory = RemoteFilePath.normalize(destinationDirectoryPath)
        let totalUnitCount = try await withClient(for: sourceServer) { client in
            try await self.countRemoteTransferUnits(for: uniqueEntries, using: client)
        }
        let progressTracker = TransferProgressTracker(
            totalUnitCount: totalUnitCount,
            onProgress: onProgress
        )

        try await withClient(for: sourceServer) { sourceClient in
            try await self.withClient(for: destinationServer) { destinationClient in
                for entry in uniqueEntries {
                    try await self.copyRemoteEntry(
                        entry,
                        to: destinationDirectory,
                        sourceClient: sourceClient,
                        destinationClient: destinationClient,
                        progressTracker: progressTracker
                    )
                }
            }
        }

        clearViewer(serverId: destinationServerId)
        await refresh(serverId: destinationServerId)
    }

    func downloadFile(
        at remotePath: String,
        to localURL: URL,
        serverId: UUID
    ) async throws {
        guard let server = server(for: serverId) else {
            throw RemoteFileBrowserError.disconnected
        }

        try await withClient(for: server) { client in
            try await client.downloadFile(at: remotePath, to: localURL)
        }
    }

    func downloadItem(
        _ entry: RemoteFileEntry,
        to localURL: URL,
        serverId: UUID
    ) async throws {
        guard let server = server(for: serverId) else {
            throw RemoteFileBrowserError.disconnected
        }

        try await withClient(for: server) { client in
            try await self.downloadItem(entry, to: localURL, using: client)
        }
    }

    func listDirectories(at path: String, serverId: UUID) async throws -> [RemoteFileEntry] {
        guard let server = server(for: serverId) else {
            throw RemoteFileBrowserError.disconnected
        }

        let normalizedPath = RemoteFilePath.normalize(path)
        let entries = try await withClient(for: server) { client in
            try await client.listDirectory(at: normalizedPath, maxEntries: Self.directoryEntryLimit)
        }
        return entries
            .filter { $0.type == .directory }
            .sortedForBrowser(using: .name, direction: .ascending)
    }

    func disconnect(serverId: UUID) {
        directoryRequestIDs.removeValue(forKey: serverId)
        viewerRequestIDs.removeValue(forKey: serverId)
        cleanupPreviewArtifact(for: states[serverId]?.viewerPayload)
        states.removeValue(forKey: serverId)

        guard let registration = clients.removeValue(forKey: serverId) else { return }
        guard registration.ownership == .owned else { return }

        Task.detached(priority: .utility) {
            await registration.client.disconnect()
        }
    }

    // MARK: - Private

    private func loadDirectory(path: String, for server: Server) async {
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

    private func resolveInitialDirectorySnapshot(for server: Server, initialPath: String?) async throws -> DirectorySnapshot {
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

        let homePath = try await withClient(for: server) { client in
            try await client.resolveHomeDirectory()
        }
        return try await directorySnapshot(path: homePath, for: server)
    }

    private func directorySnapshot(path: String, for server: Server) async throws -> DirectorySnapshot {
        let normalizedPath = RemoteFilePath.normalize(path)
        let entries = try await withClient(for: server) { client in
            try await client.listDirectory(at: normalizedPath, maxEntries: Self.directoryEntryLimit)
        }
        let filesystemStatus = try? await withClient(for: server) { client in
            try await client.fileSystemStatus(at: normalizedPath)
        }
        return DirectorySnapshot(
            path: normalizedPath,
            entries: entries,
            isTruncated: entries.count >= Self.directoryEntryLimit,
            filesystemStatus: filesystemStatus
        )
    }

    private func applyDirectorySnapshot(_ snapshot: DirectorySnapshot, for serverId: UUID) {
        updateState(for: serverId) { state in
            state.currentPath = snapshot.path
            state.entries = snapshot.entries
            state.isDirectoryTruncated = snapshot.isTruncated
            state.filesystemStatus = snapshot.filesystemStatus
            state.isLoadingDirectory = false
            state.error = nil
        }
        persistState(for: serverId)
    }

    private func selectFile(_ entry: RemoteFileEntry, serverId: UUID) {
        viewerRequestIDs[serverId] = UUID()
        cleanupPreviewArtifact(for: state(for: serverId).viewerPayload)
        updateState(for: serverId) { state in
            state.selectedEntryPath = entry.path
            state.viewerPayload = nil
            state.viewerError = nil
            state.isLoadingViewer = false
        }
    }

    private func makePreviewFileURL(for entry: RemoteFileEntry) throws -> URL {
        let previewsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VVTermRemoteFilePreviews", isDirectory: true)
        try FileManager.default.createDirectory(
            at: previewsDirectory,
            withIntermediateDirectories: true
        )

        let fileExtension = URL(fileURLWithPath: entry.name).pathExtension
        var url = previewsDirectory.appendingPathComponent(UUID().uuidString)
        if !fileExtension.isEmpty {
            url.appendPathExtension(fileExtension)
        }
        return url
    }

    private func cleanupPreviewArtifact(for payload: RemoteFileViewerPayload?) {
        guard let previewFileURL = payload?.previewFileURL else { return }
        try? FileManager.default.removeItem(at: previewFileURL)
    }

    private func borrowedClient(for serverId: UUID) -> SSHClient? {
        ConnectionSessionManager.shared.sharedStatsClient(for: serverId)
            ?? TerminalTabManager.shared.sharedStatsClient(for: serverId)
    }

    private func clientRegistration(for server: Server) -> ClientRegistration {
        if let existing = clients[server.id], existing.ownership == .owned {
            return existing
        }

        if let borrowedClient = borrowedClient(for: server.id) {
            if let existing = clients[server.id], existing.client === borrowedClient {
                return existing
            }
            let registration = ClientRegistration(client: borrowedClient, ownership: .borrowed)
            clients[server.id] = registration
            return registration
        }

        if let existing = clients[server.id], existing.ownership == .owned {
            return existing
        }

        let ownedClient = SSHClient()
        let registration = ClientRegistration(client: ownedClient, ownership: .owned)
        clients[server.id] = registration
        return registration
    }

    private func withClient<T>(
        for server: Server,
        operation: @escaping (SSHClient) async throws -> T
    ) async throws -> T {
        let registration = clientRegistration(for: server)
        let credentials = try KeychainManager.shared.getCredentials(for: server)

        do {
            return try await SSHConnectionOperationService.shared.runWithConnection(
                using: registration.client,
                server: server,
                credentials: credentials,
                disconnectWhenDone: false,
                operation: operation
            )
        } catch {
            if registration.ownership == .borrowed {
                clients.removeValue(forKey: server.id)
            }
            throw error
        }
    }

    private func bestWorkingDirectory(for serverId: UUID) -> String? {
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

    private func updateState(for serverId: UUID, mutation: (inout BrowserState) -> Void) {
        var state = states[serverId] ?? BrowserState(persisted: persistedState(for: serverId))
        mutation(&state)
        states[serverId] = state
    }

    private func performMutation(
        serverId: UUID,
        operation: @escaping (SSHClient) async throws -> Void
    ) async throws {
        guard let server = server(for: serverId) else {
            throw RemoteFileBrowserError.disconnected
        }

        try await withClient(for: server) { client in
            try await operation(client)
        }
        await refresh(serverId: serverId)
    }

    private func loadLocalFileData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: url, options: [.mappedIfSafe])
        }.value
    }

    private func localItemInfo(at url: URL) async throws -> LocalUploadItemInfo {
        try await Task.detached(priority: .utility) {
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
            return LocalUploadItemInfo(
                name: resourceValues.name ?? url.lastPathComponent,
                isDirectory: resourceValues.isDirectory == true
            )
        }.value
    }

    private func localDirectoryContents(at url: URL) async throws -> [URL] {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
                options: []
            )
            return contents.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        }.value
    }

    private func uploadItem(
        at localURL: URL,
        to remoteDirectoryPath: String,
        using client: SSHClient,
        progressTracker: TransferProgressTracker? = nil
    ) async throws {
        let itemInfo = try await localItemInfo(at: localURL)
        let remotePath = RemoteFilePath.appending(itemInfo.name, to: remoteDirectoryPath)

        if itemInfo.isDirectory {
            try await ensureRemoteDirectoryExists(
                at: remotePath,
                permissions: 0o755,
                using: client
            )
            progressTracker?.advance(currentItemName: itemInfo.name)
            let children = try await localDirectoryContents(at: localURL)
            for child in children {
                try await uploadItem(
                    at: child,
                    to: remotePath,
                    using: client,
                    progressTracker: progressTracker
                )
            }
            return
        }

        let data = try await loadLocalFileData(from: localURL)
        try await client.upload(data, to: remotePath, permissions: 0o644)
        progressTracker?.advance(currentItemName: itemInfo.name)
    }

    private func downloadItem(
        _ entry: RemoteFileEntry,
        to localURL: URL,
        using client: SSHClient
    ) async throws {
        let effectiveEntry = try await resolvedTransferEntry(for: entry, using: client)

        if effectiveEntry.type == .directory {
            try await createLocalDirectory(at: localURL)
            let children = try await client.listDirectory(at: entry.path)
            for child in children {
                let childURL = localURL.appendingPathComponent(
                    child.name,
                    isDirectory: child.type == .directory
                )
                try await downloadItem(child, to: childURL, using: client)
            }
            return
        }

        try await client.downloadFile(at: entry.path, to: localURL)
    }

    private func copyRemoteEntry(
        _ entry: RemoteFileEntry,
        to remoteDirectoryPath: String,
        sourceClient: SSHClient,
        destinationClient: SSHClient,
        progressTracker: TransferProgressTracker?
    ) async throws {
        let effectiveEntry = try await resolvedTransferEntry(for: entry, using: sourceClient)
        let remotePath = RemoteFilePath.appending(entry.name, to: remoteDirectoryPath)

        if effectiveEntry.type == .directory {
            try await ensureRemoteDirectoryExists(
                at: remotePath,
                permissions: Int32(effectiveEntry.permissions ?? 0o755),
                using: destinationClient
            )
            progressTracker?.advance(currentItemName: entry.name)
            let children = try await sourceClient.listDirectory(at: entry.path)
            for child in children {
                try await copyRemoteEntry(
                    child,
                    to: remotePath,
                    sourceClient: sourceClient,
                    destinationClient: destinationClient,
                    progressTracker: progressTracker
                )
            }
            return
        }

        let temporaryURL = try temporaryTransferURL(for: entry)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try await sourceClient.downloadFile(at: entry.path, to: temporaryURL)
        let data = try await loadLocalFileData(from: temporaryURL)
        try await destinationClient.upload(
            data,
            to: remotePath,
            permissions: Int32(effectiveEntry.permissions ?? 0o644)
        )
        progressTracker?.advance(currentItemName: entry.name)
    }

    private func countLocalTransferUnits(at urls: [URL]) async throws -> Int {
        var totalUnitCount = 0

        for url in urls {
            totalUnitCount += try await countLocalTransferUnits(at: url)
        }

        return max(1, totalUnitCount)
    }

    private func countLocalTransferUnits(at url: URL) async throws -> Int {
        let itemInfo = try await localItemInfo(at: url)
        guard itemInfo.isDirectory else { return 1 }

        let children = try await localDirectoryContents(at: url)
        var totalUnitCount = 1

        for child in children {
            totalUnitCount += try await countLocalTransferUnits(at: child)
        }

        return totalUnitCount
    }

    private func countRemoteTransferUnits(
        for entries: [RemoteFileEntry],
        using client: SSHClient
    ) async throws -> Int {
        var totalUnitCount = 0

        for entry in entries {
            totalUnitCount += try await countRemoteTransferUnits(for: entry, using: client)
        }

        return max(1, totalUnitCount)
    }

    private func countRemoteTransferUnits(
        for entry: RemoteFileEntry,
        using client: SSHClient
    ) async throws -> Int {
        let effectiveEntry = try await resolvedTransferEntry(for: entry, using: client)
        guard effectiveEntry.type == .directory else { return 1 }

        let children = try await client.listDirectory(at: entry.path)
        var totalUnitCount = 1

        for child in children {
            totalUnitCount += try await countRemoteTransferUnits(for: child, using: client)
        }

        return totalUnitCount
    }

    private func resolvedTransferEntry(
        for entry: RemoteFileEntry,
        using client: SSHClient
    ) async throws -> RemoteFileEntry {
        guard entry.type == .symlink else { return entry }

        let resolvedEntry = try await client.stat(at: entry.path)
        return RemoteFileEntry(
            name: entry.name,
            path: entry.path,
            type: resolvedEntry.type,
            size: resolvedEntry.size,
            modifiedAt: resolvedEntry.modifiedAt,
            permissions: resolvedEntry.permissions,
            symlinkTarget: entry.symlinkTarget ?? resolvedEntry.symlinkTarget
        )
    }

    private func ensureRemoteDirectoryExists(
        at remotePath: String,
        permissions: Int32,
        using client: SSHClient
    ) async throws {
        do {
            let existingEntry = try await client.lstat(at: remotePath)
            guard existingEntry.type == .directory else {
                throw RemoteFileBrowserError.failed(
                    String(
                        format: String(localized: "\"%@\" already exists and is not a folder."),
                        existingEntry.name.isEmpty ? remotePath : existingEntry.name
                    )
                )
            }
        } catch let error as RemoteFileBrowserError {
            guard case .pathNotFound = error else { throw error }
            try await client.createDirectory(at: remotePath, permissions: permissions)
        } catch {
            throw error
        }
    }

    private func temporaryTransferURL(for entry: RemoteFileEntry) throws -> URL {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VVTermTransferStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let itemName = entry.name.isEmpty ? "download" : entry.name
        return rootDirectory.appendingPathComponent(UUID().uuidString + "-" + itemName)
    }

    private func uniqueTransferEntries(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        var seenPaths: Set<String> = []
        return entries.filter { seenPaths.insert($0.path).inserted }
    }

    private func createLocalDirectory(at url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }.value
    }

    private func withSecurityScopedAccess<T>(
        to urls: [URL],
        operation: () async throws -> T
    ) async throws -> T {
        let accessedURLs = urls.map { url in
            (url: url, accessed: url.startAccessingSecurityScopedResource())
        }
        defer {
            for entry in accessedURLs where entry.accessed {
                entry.url.stopAccessingSecurityScopedResource()
            }
        }
        return try await operation()
    }

    private func server(for serverId: UUID) -> Server? {
        ServerManager.shared.servers.first { $0.id == serverId }
    }

    private func loadPersistedStates() {
        guard let data = defaults.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([String: RemoteFileBrowserPersistedState].self, from: data) else {
            persistedStates = [:]
            return
        }
        persistedStates = decoded
    }

    private func persistedState(for serverId: UUID) -> RemoteFileBrowserPersistedState {
        persistedStates[serverId.uuidString] ?? .init()
    }

    private func persistState(for serverId: UUID) {
        let state = states[serverId] ?? BrowserState(persisted: persistedState(for: serverId))
        persistedStates[serverId.uuidString] = RemoteFileBrowserPersistedState(
            lastVisitedPath: state.currentPath,
            sort: state.sort,
            sortDirection: state.sortDirection,
            showHiddenFiles: state.showHiddenFiles,
            hasCustomizedHiddenFiles: state.hasCustomizedHiddenFiles
        )

        guard let data = try? JSONEncoder().encode(persistedStates) else { return }
        defaults.set(data, forKey: persistenceKey)
    }

    private func validatedRemoteName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "A name is required."))
        }
        guard trimmed != "." && trimmed != ".." else {
            throw RemoteFileBrowserError.failed(String(localized: "This name is not allowed."))
        }
        guard !trimmed.contains("/") else {
            throw RemoteFileBrowserError.failed(String(localized: "Names cannot contain '/'."))
        }
        return trimmed
    }

}

private extension String {
    var nonEmptyString: String? {
        isEmpty ? nil : self
    }
}
