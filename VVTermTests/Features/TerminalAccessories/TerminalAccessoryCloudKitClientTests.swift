import CloudKit
import Foundation
import Testing
@testable import VVTerm

private enum TerminalAccessoryRecordTransportTestError: Error, Equatable {
    case missing
    case conflict
    case failed
}

@MainActor
private final class TerminalAccessoryRecordTransportStub: CloudKitRecordTransport {
    let cloudKitRecordZoneID = CKRecordZone.ID(
        zoneName: "TerminalAccessoryClientTests",
        ownerName: CKCurrentUserDefaultName
    )

    var fetchResult: Result<CKRecord, Error>
    var saveResults: [Result<Void, Error>] = []
    var conflictRecord: CKRecord?
    private(set) var mutationCount = 0
    private(set) var savedRecords: [CKRecord] = []
    private(set) var synchronizedCount = 0

    init(fetchResult: Result<CKRecord, Error>) {
        self.fetchResult = fetchResult
    }

    func performCloudKitRecordMutation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        mutationCount += 1
        return try await operation()
    }

    func fetchCloudKitRecord(_ recordID: CKRecord.ID) async throws -> CKRecord {
        try fetchResult.get()
    }

    func fetchCloudKitRecords(
        matchingRecordTypes recordTypes: Set<String>,
        desiredKeys: [String]
    ) async throws -> [CKRecord] {
        []
    }

    func upsertCloudKitRecord(_ record: CKRecord) async throws {}

    func saveCloudKitRecordIfUnchanged(_ record: CKRecord) async throws {
        savedRecords.append(record)
        guard !saveResults.isEmpty else { return }
        try saveResults.removeFirst().get()
    }

    func markCloudKitRecordSynchronized() {
        synchronizedCount += 1
    }

    func cloudKitServerRecord(from error: Error) -> CKRecord? {
        guard error as? TerminalAccessoryRecordTransportTestError == .conflict else {
            return nil
        }
        return conflictRecord
    }

    func isCloudKitRecordMissing(_ error: Error) -> Bool {
        error as? TerminalAccessoryRecordTransportTestError == .missing
    }
}

@MainActor
private final class TerminalAccessoryCloudClientSpy: TerminalAccessoryCloudClient {
    let resolvedProfile: TerminalAccessoryProfile
    private(set) var receivedProfiles: [TerminalAccessoryProfile] = []

    init(resolvedProfile: TerminalAccessoryProfile) {
        self.resolvedProfile = resolvedProfile
    }

    func syncTerminalAccessoryProfile(
        _ localProfile: TerminalAccessoryProfile
    ) async throws -> TerminalAccessoryProfile {
        receivedProfiles.append(localProfile)
        return resolvedProfile
    }
}

@MainActor
private final class StatsPreferencesCloudClientStub: StatsPreferencesCloudClient {
    func syncStatsPreferences(
        _ localPreferences: StatsPreferences
    ) async throws -> StatsPreferences {
        localPreferences
    }
}

@MainActor
private final class TerminalThemeCloudClientStub: TerminalThemeCloudMutationClient {
    func saveTerminalTheme(_ theme: TerminalTheme) async throws {}
    func saveTerminalThemePreference(
        _ preference: TerminalThemePreference
    ) async throws {}
}

@MainActor
private final class AccessoryReplayServerCloudClientStub: ServerRemoteMutationClient {
    func saveServer(_ server: Server) async throws {}
    func deleteServer(_ server: Server) async throws {}
    func saveWorkspace(_ workspace: Workspace) async throws {}
    func deleteWorkspace(_ workspace: Workspace) async throws {}
}

@MainActor
struct TerminalAccessoryCloudKitClientTests {
    @Test
    func testRemoteWinnerCompletesWithoutWriting() async throws {
        let local = makeProfile(time: 10, writer: "local")
        let remote = makeProfile(time: 20, writer: "remote")
        let transport = TerminalAccessoryRecordTransportStub(
            fetchResult: .success(try record(for: remote))
        )
        let client = TerminalAccessoryCloudKitClient(transport: transport)

        let resolved = try await client.syncTerminalAccessoryProfile(local)

        #expect(resolved == remote.normalized())
        #expect(transport.mutationCount == 1)
        #expect(transport.savedRecords.isEmpty)
        #expect(transport.synchronizedCount == 1)
    }

    @Test
    func testServerConflictMergesAndRetriesAgainstServerRecord() async throws {
        let local = makeProfile(time: 30, writer: "local")
        let initialRemote = makeProfile(time: 10, writer: "initial")
        let conflictRemote = makeProfile(time: 20, writer: "conflict")
        let conflictRecord = try record(for: conflictRemote)
        let transport = TerminalAccessoryRecordTransportStub(
            fetchResult: .success(try record(for: initialRemote))
        )
        transport.conflictRecord = conflictRecord
        transport.saveResults = [
            .failure(TerminalAccessoryRecordTransportTestError.conflict),
            .success(())
        ]
        let client = TerminalAccessoryCloudKitClient(transport: transport)

        let resolved = try await client.syncTerminalAccessoryProfile(local)

        #expect(resolved == local.normalized())
        #expect(transport.savedRecords.count == 2)
        #expect(transport.savedRecords[1] === conflictRecord)
        #expect(transport.synchronizedCount == 1)
    }

    @Test
    func testServerConflictReturnsNewerRemoteWithoutAnotherWrite() async throws {
        let local = makeProfile(time: 20, writer: "local")
        let initialRemote = makeProfile(time: 10, writer: "initial")
        let conflictRemote = makeProfile(time: 30, writer: "conflict")
        let transport = TerminalAccessoryRecordTransportStub(
            fetchResult: .success(try record(for: initialRemote))
        )
        transport.conflictRecord = try record(for: conflictRemote)
        transport.saveResults = [
            .failure(TerminalAccessoryRecordTransportTestError.conflict)
        ]
        let client = TerminalAccessoryCloudKitClient(transport: transport)

        let resolved = try await client.syncTerminalAccessoryProfile(local)

        #expect(resolved == conflictRemote.normalized())
        #expect(transport.savedRecords.count == 1)
        #expect(transport.synchronizedCount == 1)
    }

    @Test
    func testMissingRecordRetriesAreBounded() async {
        let local = makeProfile(time: 20, writer: "local")
        let transport = TerminalAccessoryRecordTransportStub(
            fetchResult: .failure(TerminalAccessoryRecordTransportTestError.missing)
        )
        transport.saveResults = Array(
            repeating: .failure(TerminalAccessoryRecordTransportTestError.missing),
            count: TerminalAccessoryCloudKitClient.maximumConflictAttempts
        )
        let client = TerminalAccessoryCloudKitClient(transport: transport)

        do {
            _ = try await client.syncTerminalAccessoryProfile(local)
            Issue.record("Expected bounded retry failure")
        } catch {
            #expect(error as? TerminalAccessoryCloudClientError == .conflictRetryLimitReached)
        }

        #expect(
            transport.savedRecords.count
                == TerminalAccessoryCloudKitClient.maximumConflictAttempts
        )
        #expect(transport.synchronizedCount == 0)
    }

    @Test
    func testUnclassifiedFailureIsNotRetried() async {
        let local = makeProfile(time: 20, writer: "local")
        let transport = TerminalAccessoryRecordTransportStub(
            fetchResult: .failure(TerminalAccessoryRecordTransportTestError.failed)
        )
        let client = TerminalAccessoryCloudKitClient(transport: transport)

        do {
            _ = try await client.syncTerminalAccessoryProfile(local)
            Issue.record("Expected transport failure")
        } catch {
            guard error as? TerminalAccessoryRecordTransportTestError == .failed else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(transport.savedRecords.isEmpty)
        #expect(transport.synchronizedCount == 0)
    }

    @Test
    func testQueuedReplayUsesInjectedClientAndPublishesResolution() async {
        let suiteName = "TerminalAccessoryReplayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let queued = makeProfile(time: 10, writer: "queued")
        let resolved = makeProfile(time: 20, writer: "resolved")
        let client = TerminalAccessoryCloudClientSpy(resolvedProfile: resolved)
        let resolutionHub = CloudKitSyncResolutionHub()
        var publishedProfiles: [TerminalAccessoryProfile] = []
        let observerID = resolutionHub.observe { resolution in
            guard case .terminalAccessoryProfile(let profile) = resolution else { return }
            publishedProfiles.append(profile)
        }
        defer { resolutionHub.removeObserver(observerID) }
        let coordinator = CloudKitSyncCoordinator(
            serverCloud: AccessoryReplayServerCloudClientStub(),
            terminalThemeCloud: TerminalThemeCloudClientStub(),
            terminalAccessoryCloud: client,
            statsPreferencesCloud: StatsPreferencesCloudClientStub(),
            queue: PendingCloudKitSyncQueue(
                storageKey: "terminalAccessoryReplayQueue",
                defaults: defaults
            ),
            resolutionHub: resolutionHub,
            isSyncEnabled: { true },
            now: { Date(timeIntervalSince1970: 100) }
        )

        coordinator.enqueueTerminalAccessoryProfileUpsert(queued)
        await coordinator.drainPendingMutations()

        #expect(client.receivedProfiles == [queued])
        #expect(publishedProfiles == [resolved])
        #expect(coordinator.snapshot().isEmpty)
    }

    private func record(for profile: TerminalAccessoryProfile) throws -> CKRecord {
        try TerminalAccessoryCloudKitRecordCodec.record(
            for: profile,
            recordID: TerminalAccessoryCloudKitRecordCodec.recordID(
                in: CKRecordZone.ID(
                    zoneName: "TerminalAccessoryClientTests",
                    ownerName: CKCurrentUserDefaultName
                )
            )
        )
    }

    private func makeProfile(
        time: TimeInterval,
        writer: String
    ) -> TerminalAccessoryProfile {
        var profile = TerminalAccessoryProfile.defaultValue(lastWriterDeviceId: writer)
        let date = Date(timeIntervalSince1970: time)
        profile.layout.updatedAt = date
        profile.updatedAt = date
        return profile.normalized()
    }
}
