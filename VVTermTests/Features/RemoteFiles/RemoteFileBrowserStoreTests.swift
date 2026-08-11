import Foundation
import Testing
@testable import VVTerm

@MainActor
struct RemoteFileBrowserStoreTests {
    @Test
    func displayedEntriesHideDotFilesAndKeepDirectoryOrdering() {
        let defaults = makeDefaults()
        let store = RemoteFileBrowserStore(defaults: defaults)
        let tab = makeTab()

        store.updateState(for: tab) { state in
            state.entries = [
                makeEntry(name: ".secret", path: "/tmp/.secret", type: .file),
                makeEntry(name: "docs", path: "/tmp/docs", type: .directory),
                makeEntry(name: "readme.md", path: "/tmp/readme.md", type: .file)
            ]
            state.showHiddenFiles = false
            state.sort = .name
            state.sortDirection = .ascending
        }

        #expect(store.displayedEntries(for: tab).map(\.name) == ["docs", "readme.md"])
    }

    @Test
    func persistedStateLoadsIntoFreshStoreInstance() {
        let defaults = makeDefaults()
        let tab = makeTab()

        let store = RemoteFileBrowserStore(defaults: defaults)
        store.updateState(for: tab) { state in
            state.currentPath = "/srv/releases"
            state.sort = .size
            state.sortDirection = .ascending
            state.showHiddenFiles = true
            state.hasCustomizedHiddenFiles = true
        }
        store.persistState(for: tab.id)

        let reloadedStore = RemoteFileBrowserStore(defaults: defaults)
        let persisted = reloadedStore.persistedState(for: tab.id)

        #expect(persisted.lastVisitedPath == "/srv/releases")
        #expect(persisted.sort == .size)
        #expect(persisted.sortDirection == .ascending)
        #expect(persisted.showHiddenFiles)
        #expect(persisted.hasCustomizedHiddenFiles)
    }

    @Test
    func legacyServerScopedSnapshotIsDiscardedOnLoad() throws {
        let defaults = makeDefaults()
        let legacyKey = "remoteFileBrowserState.v1"
        let legacyPayload = try JSONEncoder().encode([
            UUID().uuidString: RemoteFileBrowserPersistedState(lastVisitedPath: "/legacy")
        ])
        defaults.set(legacyPayload, forKey: legacyKey)

        let store = RemoteFileBrowserStore(defaults: defaults)

        #expect(defaults.object(forKey: legacyKey) == nil)
        #expect(store.persistedStates.isEmpty)
    }

    @Test
    func initialDirectoryCandidatesPreferPersistedPathOverSeedPath() {
        let defaults = makeDefaults()
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/etc")

        let store = RemoteFileBrowserStore(
            defaults: defaults,
            workingDirectoryProvider: { _ in "/srv/app" }
        )
        store.updateState(for: tab) { state in
            state.currentPath = "/etc/nginx"
        }
        store.persistState(for: tab.id)

        let reloadedStore = RemoteFileBrowserStore(
            defaults: defaults,
            workingDirectoryProvider: { _ in "/srv/app" }
        )
        let candidates = reloadedStore.initialDirectoryCandidates(
            for: server,
            tab: tab,
            initialPath: tab.seedPath
        )

        #expect(candidates == ["/etc/nginx", "/etc", "/srv/app"])
    }

    @Test
    func staleDirectoryCompletionCannotRecreateRemovedTabState() {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let tab = makeTab()
        let requestID = UUID()

        store.updateState(for: tab) { state in
            state.directoryPhase.begin(requestID: requestID)
        }
        store.removeRuntimeState(for: tab.id)

        store.applyDirectorySnapshot(
            .init(
                path: "/tmp",
                entries: [],
                isTruncated: false,
                filesystemStatus: nil
            ),
            to: tab,
            requestID: requestID
        )

        #expect(store.states[tab.id] == nil)
    }

    @Test
    func uploadRuntimeSurvivesScreenReconstructionAndTabRemovalCancelsWork() async {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/tmp")
        let cancellationProbe = RemoteFileUploadCancellationProbe()
        let firstRuntime = store.uploadRuntime(for: tab, server: server)

        let operationID = firstRuntime.start(
            title: "Uploading",
            initialMessage: "Preparing",
            successMessage: "Complete"
        ) { _ in
            try await cancellationProbe.run()
        }
        #expect(await cancellationProbe.waitUntilStarted())

        let reconstructedScreenRuntime = store.uploadRuntime(for: tab, server: server)
        #expect(firstRuntime === reconstructedScreenRuntime)
        #expect(reconstructedScreenRuntime.contains(operationID))

        store.removeRuntimeState(for: tab.id)

        #expect(!firstRuntime.contains(operationID))
        #expect(await cancellationProbe.waitUntilCancelled())
    }

    @Test(arguments: [1_999, 2_000, 2_001])
    func directoryListingTruncatesOnlyWhenAnExtraEntryExists(entryCount: Int) {
        let entries = (0..<entryCount).map { index in
            makeEntry(
                name: "entry-\(index)",
                path: "/tmp/entry-\(index)",
                type: .file
            )
        }

        let listing = RemoteFileBrowserStore.cappedDirectoryListing(entries)

        #expect(listing.entries.count == min(entryCount, 2_000))
        #expect(listing.isTruncated == (entryCount > 2_000))
    }

    @Test
    func bulkDirectoryListingKeepsSymlinkTargetUnresolved() {
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        attributes.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)
        attributes.permissions = UInt(LIBSSH2_SFTP_S_IFLNK | LIBSSH2_SFTP_S_IRUSR)

        let entry = SSHSession.directoryListingEntry(
            name: "current",
            path: "/srv/current",
            attributes: attributes
        )

        #expect(entry.type == .symlink)
        #expect(entry.symlinkTarget == nil)
    }

    private func makeEntry(name: String, path: String, type: RemoteFileType) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: path,
            type: type,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }

    private func makeTab() -> RemoteFileTab {
        RemoteFileTab(serverId: UUID(), seedPath: "/tmp")
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Production",
            host: "example.com",
            username: "root"
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RemoteFileBrowserStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private actor RemoteFileUploadCancellationProbe {
    private var didStart = false
    private var didObserveCancellation = false

    func run() async throws {
        didStart = true
        while !Task.isCancelled {
            await Task.yield()
        }
        didObserveCancellation = true
        throw CancellationError()
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<2_000 {
            if didStart { return true }
            await Task.yield()
        }
        return didStart
    }

    func waitUntilCancelled() async -> Bool {
        for _ in 0..<2_000 {
            if didObserveCancellation { return true }
            await Task.yield()
        }
        return didObserveCancellation
    }
}
