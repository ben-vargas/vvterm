import Foundation
import Testing
@testable import VVTerm

struct PendingCloudKitSyncTests {
    @Test
    func everySupportedMutationRoundTrips() throws {
        let fixtures = PendingSyncFixtures()

        for (index, payload) in fixtures.supportedPayloads.enumerated() {
            let mutation = PendingCloudKitMutation(
                id: fixtures.mutationIDs[index],
                payload: payload,
                createdAt: fixtures.createdAt.addingTimeInterval(TimeInterval(index)),
                retryCount: index,
                nextRetryAt: fixtures.createdAt.addingTimeInterval(120),
                lastErrorCode: "error-\(index)",
                lastErrorDescription: "failure-\(index)"
            )

            let encoded = try JSONEncoder().encode(mutation)
            let decoded = try JSONDecoder().decode(PendingCloudKitMutation.self, from: encoded)

            #expect(decoded == mutation)
        }
    }

    @Test
    func previouslyPersistedAssociatedPayloadDecodesWithoutMigration() throws {
        let data = Data(#"""
        {
          "id": "10000000-0000-0000-0000-000000000001",
          "payload": {
            "kind": "terminalThemeUpsert",
            "payload": {
              "id": "20000000-0000-0000-0000-000000000002",
              "name": "Durable Theme",
              "content": "background = #000000\nforeground = #FFFFFF\n",
              "updatedAt": 1234
            }
          },
          "createdAt": 1000,
          "retryCount": 2,
          "nextRetryAt": 1060,
          "lastErrorCode": "networkFailure",
          "lastErrorDescription": "offline"
        }
        """#.utf8)

        let mutation = try JSONDecoder().decode(PendingCloudKitMutation.self, from: data)
        let expectedTheme = TerminalTheme(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            name: "Durable Theme",
            content: "background = #000000\nforeground = #FFFFFF\n",
            updatedAt: Date(timeIntervalSinceReferenceDate: 1_234)
        )

        #expect(mutation.id == UUID(uuidString: "10000000-0000-0000-0000-000000000001"))
        #expect(mutation.payload == .terminalThemeUpsert(expectedTheme))
        #expect(mutation.createdAt == Date(timeIntervalSinceReferenceDate: 1_000))
        #expect(mutation.retryCount == 2)
        #expect(mutation.nextRetryAt == Date(timeIntervalSinceReferenceDate: 1_060))
        #expect(mutation.lastErrorCode == "networkFailure")
        #expect(mutation.lastErrorDescription == "offline")
    }

    @Test
    func everyValidLegacyCombinationMigratesWithoutQuarantine() throws {
        let fixtures = PendingSyncFixtures()
        let storage = makeStorage()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }

        let legacyMutations = fixtures.validLegacyMutations
        storage.defaults.set(try JSONEncoder().encode(legacyMutations), forKey: storage.storageKey)

        let queue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )

        #expect(queue.snapshot().map(\.payload) == fixtures.migratedLegacyPayloads)
        #expect(queue.snapshot().map(\.id) == Array(fixtures.mutationIDs.prefix(9)))
        #expect(queue.snapshot().allSatisfy { $0.retryCount == 2 })
        #expect(queue.quarantineSnapshot().isEmpty)

        let reloadedQueue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )
        #expect(reloadedQueue.snapshot() == queue.snapshot())
        #expect(reloadedQueue.quarantineSnapshot().isEmpty)
    }

    @Test
    func invalidLegacyRecordsAreQuarantinedWithoutLosingValidRecords() throws {
        let fixtures = PendingSyncFixtures()
        let storage = makeStorage()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }

        let valid = LegacyMutationFixture(
            id: fixtures.mutationIDs[0],
            entity: "server",
            operation: "upsert",
            entityKey: fixtures.server.id.uuidString,
            server: fixtures.server
        )
        let missingPayload = LegacyMutationFixture(
            id: fixtures.mutationIDs[1],
            entity: "workspace",
            operation: "upsert",
            entityKey: fixtures.workspace.id.uuidString
        )
        let conflictingPayloads = LegacyMutationFixture(
            id: fixtures.mutationIDs[2],
            entity: "server",
            operation: "upsert",
            entityKey: fixtures.server.id.uuidString,
            server: fixtures.server,
            workspace: fixtures.workspace
        )
        let mismatchedEntityKey = LegacyMutationFixture(
            id: fixtures.mutationIDs[3],
            entity: "workspace",
            operation: "delete",
            entityKey: UUID().uuidString,
            workspace: fixtures.deletedWorkspace
        )
        let unsupportedDelete = LegacyMutationFixture(
            id: fixtures.mutationIDs[4],
            entity: "terminalAccessoryProfile",
            operation: "delete",
            entityKey: TerminalAccessoryProfile.recordName
        )

        let records: [Any] = try [
            valid,
            missingPayload,
            conflictingPayloads,
            mismatchedEntityKey,
            unsupportedDelete
        ].map(jsonObject) + ["unreadable legacy mutation"]
        let legacyData = try JSONSerialization.data(withJSONObject: records)
        storage.defaults.set(legacyData, forKey: storage.storageKey)

        let queue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )

        #expect(queue.snapshot().map(\.payload) == [.serverUpsert(fixtures.server)])
        #expect(queue.quarantineSnapshot().count == 5)
        #expect(queue.quarantineSnapshot().allSatisfy { !$0.encodedLegacyRecord.isEmpty })
        #expect(queue.quarantineSnapshot().contains { $0.reason == .missingOrConflictingPayload })
        #expect(queue.quarantineSnapshot().contains { $0.reason == .mismatchedEntityKey })
        #expect(queue.quarantineSnapshot().contains { $0.reason == .unsupportedOperation })
        #expect(queue.quarantineSnapshot().contains { $0.reason == .unreadableLegacyRecord })

        let reloadedQueue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )
        #expect(reloadedQueue.snapshot() == queue.snapshot())
        #expect(reloadedQueue.quarantineSnapshot() == queue.quarantineSnapshot())
    }

    @Test
    func retryCountAndExponentialDelaySaturate() {
        let fixtures = PendingSyncFixtures()
        let now = Date(timeIntervalSinceReferenceDate: 50_000)
        let error = RetryTestError()

        let firstFailure = PendingCloudKitMutation(
            payload: .serverUpsert(fixtures.server)
        ).withFailure(error: error, at: now)
        #expect(firstFailure.retryCount == 1)
        #expect(firstFailure.nextRetryAt == now.addingTimeInterval(30))

        let negativeCount = PendingCloudKitMutation(
            payload: .serverUpsert(fixtures.server),
            retryCount: Int.min
        )
        #expect(negativeCount.retryCount == 0)

        let cappedDelay = PendingCloudKitMutation(
            payload: .serverUpsert(fixtures.server),
            retryCount: 7
        ).withFailure(error: error, at: now)
        #expect(cappedDelay.retryCount == 8)
        #expect(cappedDelay.nextRetryAt == now.addingTimeInterval(3_600))

        let saturatedCount = PendingCloudKitMutation(
            payload: .serverUpsert(fixtures.server),
            retryCount: Int.max
        )
        #expect(saturatedCount.retryCount == PendingCloudKitMutation.maximumRetryCount)

        let saturatedFailure = saturatedCount.withFailure(error: error, at: now)
        #expect(saturatedFailure.retryCount == PendingCloudKitMutation.maximumRetryCount)
        #expect(saturatedFailure.nextRetryAt == now.addingTimeInterval(3_600))
    }

    @Test
    func enqueueCoalescesOnlyTheSameEntityAndKey() {
        let fixtures = PendingSyncFixtures()
        let storage = makeStorage()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }
        let queue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )

        queue.enqueue(PendingCloudKitMutation(payload: .serverUpsert(fixtures.server)))
        queue.enqueue(
            PendingCloudKitMutation(payload: .workspaceUpsert(fixtures.workspaceWithServerID))
        )
        queue.enqueue(PendingCloudKitMutation(payload: .serverDelete(fixtures.deletedServer)))

        #expect(
            queue.snapshot().map(\.payload) == [
                .workspaceUpsert(fixtures.workspaceWithServerID),
                .serverDelete(fixtures.deletedServer)
            ]
        )

        queue.enqueue(
            PendingCloudKitMutation(
                payload: .workspaceDelete(fixtures.deletedWorkspaceWithServerID)
            )
        )
        #expect(
            queue.snapshot().map(\.payload) == [
                .serverDelete(fixtures.deletedServer),
                .workspaceDelete(fixtures.deletedWorkspaceWithServerID)
            ]
        )

        let reloadedQueue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )
        #expect(reloadedQueue.snapshot() == queue.snapshot())
    }

    @Test
    func atomicBatchCoalescesAllMutationsBeforeOnePersistedSnapshot() throws {
        let fixtures = PendingSyncFixtures()
        let storage = makeStorage()
        defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }
        let queue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )
        queue.enqueue(PendingCloudKitMutation(payload: .serverUpsert(fixtures.server)))
        queue.enqueue(
            PendingCloudKitMutation(payload: .workspaceUpsert(fixtures.workspaceWithServerID))
        )

        try queue.enqueueAtomically([
            PendingCloudKitMutation(payload: .serverDelete(fixtures.deletedServer)),
            PendingCloudKitMutation(
                payload: .workspaceDelete(fixtures.deletedWorkspaceWithServerID)
            )
        ])

        #expect(queue.snapshot().map(\.payload) == [
            .serverDelete(fixtures.deletedServer),
            .workspaceDelete(fixtures.deletedWorkspaceWithServerID)
        ])
        let reloadedQueue = PendingCloudKitSyncQueue(
            storageKey: storage.storageKey,
            defaults: storage.defaults
        )
        #expect(reloadedQueue.snapshot() == queue.snapshot())
    }

    @Test
    func drainOrderPreservesDependenciesAndDefersDeletes() {
        let fixtures = PendingSyncFixtures()
        let mutations = fixtures.supportedPayloads.reversed().enumerated().map { index, payload in
            PendingCloudKitMutation(
                id: fixtures.mutationIDs[index],
                payload: payload,
                createdAt: fixtures.createdAt
            )
        }

        let orderedPayloads = mutations
            .sorted(by: PendingCloudKitMutation.drainsBefore)
            .map(\.payload)

        #expect(orderedPayloads == fixtures.payloadsInDrainOrder)

        let later = PendingCloudKitMutation(
            id: fixtures.mutationIDs[1],
            payload: .terminalThemeUpsert(fixtures.theme),
            createdAt: fixtures.createdAt.addingTimeInterval(1)
        )
        let earlier = PendingCloudKitMutation(
            id: fixtures.mutationIDs[2],
            payload: .terminalThemeUpsert(fixtures.theme),
            createdAt: fixtures.createdAt
        )
        #expect([later, earlier].sorted(by: PendingCloudKitMutation.drainsBefore) == [earlier, later])

        let lowerID = PendingCloudKitMutation(
            id: fixtures.mutationIDs[0],
            payload: .terminalThemeUpsert(fixtures.theme),
            createdAt: fixtures.createdAt
        )
        let higherID = PendingCloudKitMutation(
            id: fixtures.mutationIDs[1],
            payload: .terminalThemeUpsert(fixtures.theme),
            createdAt: fixtures.createdAt
        )
        #expect(
            [higherID, lowerID].sorted(by: PendingCloudKitMutation.drainsBefore) == [lowerID, higherID]
        )
    }
}

private struct PendingSyncFixtures {
    let createdAt = Date(timeIntervalSinceReferenceDate: 10_000)
    let mutationIDs = (1...12).map {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!
    }

    let workspace: Workspace
    let deletedWorkspace: Workspace
    let server: Server
    let deletedServer: Server
    let legacyDeletedServer: Server
    let workspaceWithServerID: Workspace
    let deletedWorkspaceWithServerID: Workspace
    let theme: TerminalTheme
    let legacyDeletedTheme: TerminalTheme
    let themePreference: TerminalThemePreference
    let accessoryProfile: TerminalAccessoryProfile
    let statsPreferences: StatsPreferences

    init() {
        let createdAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let workspaceID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let deletedWorkspaceID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let serverID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!

        workspace = Workspace(
            id: workspaceID,
            name: "Primary",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        deletedWorkspace = Workspace(
            id: deletedWorkspaceID,
            name: "Removed",
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(1)
        )
        server = Server(
            id: serverID,
            workspaceId: workspaceID,
            name: "Production",
            host: "example.test",
            username: "tester",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        deletedServer = Server(
            id: serverID,
            workspaceId: workspaceID,
            name: "Production",
            host: "example.test",
            username: "tester",
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(1)
        )
        legacyDeletedServer = Server(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            workspaceId: workspaceID,
            name: "Legacy Removed",
            host: "removed.example.test",
            username: "tester",
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(1)
        )
        workspaceWithServerID = Workspace(
            id: serverID,
            name: "Same UUID, different entity",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        deletedWorkspaceWithServerID = Workspace(
            id: serverID,
            name: "Same UUID, deleted",
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(1)
        )
        theme = TerminalTheme(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            name: "Queue Theme",
            content: "[colors]\nbackground = '#000000'",
            updatedAt: createdAt
        )
        legacyDeletedTheme = TerminalTheme(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            name: "Legacy Delete",
            content: "[colors]\nbackground = '#111111'",
            updatedAt: createdAt.addingTimeInterval(1),
            deletedAt: createdAt.addingTimeInterval(1)
        )
        themePreference = TerminalThemePreference(
            darkThemeName: "Queue Theme",
            lightThemeName: "Queue Theme",
            usePerAppearanceTheme: false,
            updatedAt: createdAt
        )
        accessoryProfile = TerminalAccessoryProfile(
            schemaVersion: TerminalAccessoryProfile.schemaVersion,
            layout: TerminalAccessoryLayout(
                version: 1,
                activeItems: [],
                updatedAt: createdAt
            ),
            customActions: [],
            updatedAt: createdAt,
            lastWriterDeviceId: "test-device"
        )
        statsPreferences = StatsPreferences(
            style: .classic,
            blocks: [],
            updatedAt: createdAt,
            lastWriterDeviceId: "test-device"
        )
    }

    var supportedPayloads: [PendingCloudKitMutationPayload] {
        [
            .serverUpsert(server),
            .serverDelete(deletedServer),
            .workspaceUpsert(workspace),
            .workspaceDelete(deletedWorkspace),
            .terminalThemeUpsert(theme),
            .terminalThemePreferenceUpsert(themePreference),
            .terminalAccessoryProfileUpsert(accessoryProfile),
            .statsPreferencesUpsert(statsPreferences)
        ]
    }

    var payloadsInDrainOrder: [PendingCloudKitMutationPayload] {
        [
            .workspaceUpsert(workspace),
            .serverUpsert(server),
            .terminalThemeUpsert(theme),
            .terminalThemePreferenceUpsert(themePreference),
            .terminalAccessoryProfileUpsert(accessoryProfile),
            .statsPreferencesUpsert(statsPreferences),
            .serverDelete(deletedServer),
            .workspaceDelete(deletedWorkspace)
        ]
    }

    var validLegacyMutations: [LegacyMutationFixture] {
        [
            LegacyMutationFixture(
                id: mutationIDs[0],
                entity: "server",
                operation: "upsert",
                entityKey: server.id.uuidString,
                server: server
            ),
            LegacyMutationFixture(
                id: mutationIDs[1],
                entity: "server",
                operation: "delete",
                entityKey: legacyDeletedServer.id.uuidString,
                server: legacyDeletedServer
            ),
            LegacyMutationFixture(
                id: mutationIDs[2],
                entity: "workspace",
                operation: "upsert",
                entityKey: workspace.id.uuidString,
                workspace: workspace
            ),
            LegacyMutationFixture(
                id: mutationIDs[3],
                entity: "workspace",
                operation: "delete",
                entityKey: deletedWorkspace.id.uuidString,
                workspace: deletedWorkspace
            ),
            LegacyMutationFixture(
                id: mutationIDs[4],
                entity: "terminalTheme",
                operation: "upsert",
                entityKey: theme.id.uuidString,
                terminalTheme: theme
            ),
            LegacyMutationFixture(
                id: mutationIDs[5],
                entity: "terminalTheme",
                operation: "delete",
                entityKey: legacyDeletedTheme.id.uuidString,
                terminalTheme: legacyDeletedTheme
            ),
            LegacyMutationFixture(
                id: mutationIDs[6],
                entity: "terminalThemePreference",
                operation: "upsert",
                entityKey: TerminalThemePreference.recordName,
                terminalThemePreference: themePreference
            ),
            LegacyMutationFixture(
                id: mutationIDs[7],
                entity: "terminalAccessoryProfile",
                operation: "upsert",
                entityKey: TerminalAccessoryProfile.recordName,
                terminalAccessoryProfile: accessoryProfile
            ),
            LegacyMutationFixture(
                id: mutationIDs[8],
                entity: "statsPreferences",
                operation: "upsert",
                entityKey: StatsPreferences.recordName,
                statsPreferences: statsPreferences
            )
        ]
    }

    var migratedLegacyPayloads: [PendingCloudKitMutationPayload] {
        [
            .serverUpsert(server),
            .serverDelete(legacyDeletedServer),
            .workspaceUpsert(workspace),
            .workspaceDelete(deletedWorkspace),
            .terminalThemeUpsert(theme),
            .terminalThemeUpsert(legacyDeletedTheme),
            .terminalThemePreferenceUpsert(themePreference),
            .terminalAccessoryProfileUpsert(accessoryProfile),
            .statsPreferencesUpsert(statsPreferences)
        ]
    }
}

private struct LegacyMutationFixture: Encodable {
    let id: UUID
    let entity: String
    let operation: String
    let entityKey: String
    var server: Server? = nil
    var workspace: Workspace? = nil
    var terminalTheme: TerminalTheme? = nil
    var terminalThemePreference: TerminalThemePreference? = nil
    var terminalAccessoryProfile: TerminalAccessoryProfile? = nil
    var statsPreferences: StatsPreferences? = nil
    var createdAt = Date(timeIntervalSinceReferenceDate: 10_000)
    var retryCount = 2
    var nextRetryAt: Date? = Date(timeIntervalSinceReferenceDate: 10_120)
    var lastErrorCode: String? = "legacy-error"
    var lastErrorDescription: String? = "Legacy failure"
}

private struct RetryTestError: Error {}

private func jsonObject(_ fixture: LegacyMutationFixture) throws -> Any {
    let encoded = try JSONEncoder().encode(fixture)
    return try JSONSerialization.jsonObject(with: encoded)
}

private func makeStorage() -> (suiteName: String, storageKey: String, defaults: UserDefaults) {
    let suiteName = "PendingCloudKitSyncTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (suiteName, "pending-mutations", defaults)
}
