import Foundation
import Testing
@testable import VVTerm

@MainActor
struct ServerLocalStoreTests {
    @Test
    func missingDataIsDifferentFromAnEmptyCollection() throws {
        let fixture = try makeDefaults()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        let store = ServerLocalStore(defaults: defaults)

        guard case .missing = store.loadServers() else {
            Issue.record("Expected missing server data")
            return
        }

        try store.storeServers([])
        guard case .loaded(let servers) = store.loadServers() else {
            Issue.record("Expected a stored empty server collection")
            return
        }
        #expect(servers.isEmpty)
    }

    @Test
    func corruptDataIsQuarantinedBeforeAReplacementWrite() throws {
        let fixture = try makeDefaults()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        let corruptData = Data("not-json".utf8)
        defaults.set(corruptData, forKey: CloudKitSyncConstants.serverStorageKey)
        let store = ServerLocalStore(defaults: defaults)

        guard case .unreadable(let issue) = store.loadServers() else {
            Issue.record("Expected unreadable server data")
            return
        }

        #expect(defaults.data(forKey: issue.quarantineKey) == corruptData)
        try store.storeServers([])
        #expect(defaults.data(forKey: issue.quarantineKey) == corruptData)
    }

    @Test
    func incompatibleWorkspaceDataIsQuarantined() throws {
        let fixture = try makeDefaults()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        let incompatibleData = try JSONSerialization.data(
            withJSONObject: [["id": UUID().uuidString, "unknown": true]]
        )
        defaults.set(incompatibleData, forKey: CloudKitSyncConstants.workspaceStorageKey)
        let store = ServerLocalStore(defaults: defaults)

        guard case .unreadable(let issue) = store.loadWorkspaces() else {
            Issue.record("Expected incompatible workspace data")
            return
        }

        #expect(issue.collection == .workspaces)
        #expect(defaults.data(forKey: issue.quarantineKey) == incompatibleData)
    }

    @Test
    func repeatedDecodeFailuresKeepTheFirstQuarantineCopy() throws {
        let fixture = try makeDefaults()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        let firstData = Data("first-corrupt-copy".utf8)
        let secondData = Data("second-corrupt-copy".utf8)
        defaults.set(firstData, forKey: CloudKitSyncConstants.serverStorageKey)
        let store = ServerLocalStore(defaults: defaults)

        guard case .unreadable(let firstIssue) = store.loadServers() else {
            Issue.record("Expected the first decode failure")
            return
        }
        defaults.set(secondData, forKey: CloudKitSyncConstants.serverStorageKey)
        guard case .unreadable = store.loadServers() else {
            Issue.record("Expected the second decode failure")
            return
        }

        #expect(defaults.data(forKey: firstIssue.quarantineKey) == firstData)
    }

    private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "ServerLocalStoreTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
