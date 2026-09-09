import Foundation

extension RemoteFileBrowserStore {
    /// Mark loading before the Files screen appears, so its initial load cannot replace this request.
    func openLinkedPath(_ path: String, in tab: RemoteFileTab, server: Server) {
        guard tab.serverId == server.id else { return }
        linkedPathTasks.removeValue(forKey: tab.id)?.cancel()
        let requestID = UUID()
        cleanupPreviewArtifact(for: state(for: tab).viewerPayload)
        updateState(for: tab) { state in
            state.directoryPhase.begin(requestID: requestID)
            state.viewerPhase = .idle
        }
        linkedPathTasks[tab.id] = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let result = try await withRemoteFileService(for: server) { service in
                    try await Self.linkedPathSnapshot(path, service: service)
                }
                try Task.checkCancellation()
                applyLinkedPathSnapshot(result, to: tab, requestID: requestID)
            } catch {
                guard !Task.isCancelled else { return }
                updateExistingState(for: tab) { state in
                    state.directoryPhase.failLink(requestID: requestID, path: path, error: .map(error))
                }
            }
            // Replacement and removal cancel this task before changing its dictionary entry.
            guard !Task.isCancelled else { return }
            linkedPathTasks[tab.id] = nil
        }
    }

    static func linkedPathSnapshot(
        _ path: String,
        service: any RemoteFileService
    ) async throws -> (directory: DirectorySnapshot, file: RemoteFileEntry?) {
        let path = RemoteFilePath.normalize(path)
        let entry = try await service.stat(at: path)
        try Task.checkCancellation()
        let directoryPath = entry.type == .directory ? path : RemoteFilePath.parent(of: path)
        let entries = try await service.listDirectory(at: directoryPath, maxEntries: directoryEntryLimit + 1)
        var listing = cappedDirectoryListing(entries)
        if entry.type != .directory, !listing.entries.contains(where: { $0.path == entry.path }) {
            // A direct link can name a file beyond the bounded directory listing.
            if listing.entries.count == directoryEntryLimit { listing.entries.removeLast() }
            listing.entries.append(entry)
        }
        let capacity = try? await service.fileSystemCapacity(at: directoryPath).status
        try Task.checkCancellation()
        return (
            DirectorySnapshot(path: directoryPath, entries: listing.entries,
                              isTruncated: listing.isTruncated, filesystemStatus: capacity),
            entry.type == .directory ? nil : entry
        )
    }

    func applyLinkedPathSnapshot(
        _ result: (directory: DirectorySnapshot, file: RemoteFileEntry?),
        to tab: RemoteFileTab,
        requestID: UUID
    ) {
        guard case .loading(let currentID, _) = states[tab.id]?.directoryPhase,
              currentID == requestID else { return }
        applyDirectorySnapshot(result.directory, to: tab, requestID: requestID)
        if let file = result.file {
            if file.isHidden { setShowHiddenFiles(true, for: tab) }
            selectFile(file, in: tab)
        }
    }
}
