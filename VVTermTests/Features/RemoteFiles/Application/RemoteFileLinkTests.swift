import Foundation
import Testing
@testable import VVTerm

@MainActor
struct RemoteFileLinkTests: RemoteFileTransferTestSupport {
    @Test
    func fileLinkLoadsParentAndSelectsExactFile() async throws {
        let file = makeEntry(name: "a b.txt", path: "/tmp/a b.txt")
        let service = RecordingRemoteFileService(directoryContents: ["/tmp": [file]], statEntries: [file.path: file])
        let result = try await RemoteFileBrowserStore.linkedPathSnapshot(file.path, service: service)
        #expect(result.directory.path == "/tmp")
        #expect(result.file == file)
        #expect(service.listedPaths == ["/tmp"])
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let tab = RemoteFileTab(serverId: UUID())
        let requestID = UUID()
        store.updateState(for: tab) { $0.directoryPhase.begin(requestID: requestID) }
        store.applyLinkedPathSnapshot(result, to: tab, requestID: requestID)
        #expect(store.currentPath(for: tab) == "/tmp")
        #expect(store.selectedEntryPath(for: tab) == file.path)
    }

    @Test
    func directoryLinkOpensDirectoryWithoutFileSelection() async throws {
        let directory = makeEntry(name: "docs", path: "/srv/docs", type: .directory)
        let service = RecordingRemoteFileService(directoryContents: [:], statEntries: [directory.path: directory])
        let result = try await RemoteFileBrowserStore.linkedPathSnapshot(directory.path, service: service)
        #expect(result.directory.path == directory.path)
        #expect(result.file == nil)
        #expect(service.listedPaths == [directory.path])
    }

    @Test
    func fileOutsideDirectoryLimitRemainsVisibleWithoutExceedingLimit() async throws {
        let file = makeEntry(name: ".target", path: "/tmp/.target")
        let entries = (0...RemoteFileBrowserStore.directoryEntryLimit).map {
            makeEntry(name: "item-\($0)", path: "/tmp/item-\($0)")
        }
        let service = RecordingRemoteFileService(directoryContents: ["/tmp": entries], statEntries: [file.path: file])
        let result = try await RemoteFileBrowserStore.linkedPathSnapshot(file.path, service: service)
        #expect(result.directory.entries.count == RemoteFileBrowserStore.directoryEntryLimit)
        #expect(result.directory.entries.contains(file))
        #expect(result.directory.isTruncated)
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let tab = RemoteFileTab(serverId: UUID())
        let requestID = UUID()
        store.updateState(for: tab) { $0.directoryPhase.begin(requestID: requestID) }
        store.applyLinkedPathSnapshot(result, to: tab, requestID: requestID)
        #expect(store.displayedEntries(for: tab).contains(file))
    }

    @Test
    func missingLinkDoesNotFallBackToHome() async {
        let service = RecordingRemoteFileService(directoryContents: [:])
        await #expect(throws: RemoteFileBrowserError.pathNotFound) {
            try await RemoteFileBrowserStore.linkedPathSnapshot("/missing", service: service)
        }
        #expect(service.listedPaths.isEmpty)
    }

    @Test
    func failedExplicitLinkIsNotReplacedByScreenInitialLoad() async {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let server = Server(workspaceId: UUID(), name: "Test", host: "example.com", username: "test")
        let tab = RemoteFileTab(serverId: server.id)
        store.updateState(for: tab) { $0.directoryPhase = .failedLink(path: "/missing", error: .pathNotFound) }
        await store.loadInitialPath(for: server, tab: tab)
        #expect(store.error(for: tab) == .pathNotFound)
    }

    @Test
    func retryKeepsTheOriginalRemoteLinkPath() async {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let server = Server(workspaceId: UUID(), name: "Test", host: "example.com", username: "test")
        let tab = RemoteFileTab(serverId: server.id)
        store.updateState(for: tab) { $0.directoryPhase = .failedLink(path: "/missing/file.txt", error: .pathNotFound) }
        await store.refresh(server: server, tab: tab)
        await store.linkedPathTasks[tab.id]?.value
        #expect(store.state(for: tab).directoryPhase == .failedLink(path: "/missing/file.txt", error: .disconnected))
    }

    @Test
    func staleLinkCannotReplaceNavigationOrRecreateClosedTab() {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let tab = RemoteFileTab(serverId: UUID())
        let oldRequestID = UUID()
        let currentRequestID = UUID()
        let file = makeEntry(name: "a", path: "/old/a")
        let result = (directory: RemoteFileBrowserStore.DirectorySnapshot(path: "/old", entries: [file], isTruncated: false, filesystemStatus: nil), file: Optional(file))
        store.updateState(for: tab) { $0.directoryPhase.begin(requestID: currentRequestID) }
        store.applyLinkedPathSnapshot(result, to: tab, requestID: oldRequestID)
        #expect(store.selectedEntryPath(for: tab) == nil)
        #expect(store.state(for: tab).isLoadingDirectory)
        store.removeRuntimeState(for: tab.id)
        store.applyLinkedPathSnapshot(result, to: tab, requestID: currentRequestID)
        #expect(store.states[tab.id] == nil)
    }

    @Test
    func linkMarksLoadingBeforeScreenStartsAndClosingTabCancelsTask() {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let server = Server(workspaceId: UUID(), name: "Test", host: "example.com", username: "test")
        let tab = RemoteFileTab(serverId: server.id)
        store.openLinkedPath("/tmp/test", in: tab, server: server)
        #expect(store.isLoading(for: tab))
        let task = store.linkedPathTasks[tab.id]
        store.removeRuntimeState(for: tab.id)
        #expect(task?.isCancelled == true)
        #expect(store.linkedPathTasks[tab.id] == nil)
    }
}
