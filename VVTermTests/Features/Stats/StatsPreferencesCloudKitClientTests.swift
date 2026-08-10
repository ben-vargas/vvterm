import CloudKit
import Foundation
import Testing
@testable import VVTerm

private enum StatsPreferencesRecordTransportTestError: Error, Equatable {
    case missing
    case conflict
    case failed
}

@MainActor
private final class StatsPreferencesRecordTransportStub: CloudKitRecordTransport {
    let cloudKitRecordZoneID = CKRecordZone.ID(
        zoneName: "StatsPreferencesClientTests",
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

    func saveCloudKitRecordIfUnchanged(_ record: CKRecord) async throws {
        savedRecords.append(record)
        guard !saveResults.isEmpty else { return }
        try saveResults.removeFirst().get()
    }

    func markCloudKitRecordSynchronized() {
        synchronizedCount += 1
    }

    func cloudKitServerRecord(from error: Error) -> CKRecord? {
        guard error as? StatsPreferencesRecordTransportTestError == .conflict else {
            return nil
        }
        return conflictRecord
    }

    func isCloudKitRecordMissing(_ error: Error) -> Bool {
        error as? StatsPreferencesRecordTransportTestError == .missing
    }
}

@MainActor
struct StatsPreferencesCloudKitClientTests {
    @Test
    func testRemoteWinnerCompletesWithoutWriting() async throws {
        let local = makePreferences(style: .cardsCompact, time: 10, writer: "local")
        let remote = makePreferences(style: .classic, time: 20, writer: "remote")
        let transport = StatsPreferencesRecordTransportStub(
            fetchResult: .success(try record(for: remote))
        )
        let client = StatsPreferencesCloudKitClient(transport: transport)

        let resolved = try await client.syncStatsPreferences(local)

        #expect(resolved == remote.normalized())
        #expect(transport.mutationCount == 1)
        #expect(transport.savedRecords.isEmpty)
        #expect(transport.synchronizedCount == 1)
    }

    @Test
    func testServerConflictMergesAndRetriesAgainstServerRecord() async throws {
        let local = makePreferences(style: .classic, time: 30, writer: "local")
        let initialRemote = makePreferences(style: .cardsCompact, time: 10, writer: "initial")
        let conflictRemote = makePreferences(style: .cardsDetailed, time: 20, writer: "conflict")
        let conflictRecord = try record(for: conflictRemote)
        let transport = StatsPreferencesRecordTransportStub(
            fetchResult: .success(try record(for: initialRemote))
        )
        transport.conflictRecord = conflictRecord
        transport.saveResults = [
            .failure(StatsPreferencesRecordTransportTestError.conflict),
            .success(())
        ]
        let client = StatsPreferencesCloudKitClient(transport: transport)

        let resolved = try await client.syncStatsPreferences(local)

        #expect(resolved == local.normalized())
        #expect(transport.savedRecords.count == 2)
        #expect(transport.savedRecords[1] === conflictRecord)
        #expect(transport.synchronizedCount == 1)
    }

    @Test
    func testServerConflictReturnsNewerRemoteWithoutAnotherWrite() async throws {
        let local = makePreferences(style: .classic, time: 20, writer: "local")
        let initialRemote = makePreferences(style: .cardsCompact, time: 10, writer: "initial")
        let conflictRemote = makePreferences(style: .cardsDetailed, time: 30, writer: "conflict")
        let transport = StatsPreferencesRecordTransportStub(
            fetchResult: .success(try record(for: initialRemote))
        )
        transport.conflictRecord = try record(for: conflictRemote)
        transport.saveResults = [
            .failure(StatsPreferencesRecordTransportTestError.conflict)
        ]
        let client = StatsPreferencesCloudKitClient(transport: transport)

        let resolved = try await client.syncStatsPreferences(local)

        #expect(resolved == conflictRemote.normalized())
        #expect(transport.savedRecords.count == 1)
        #expect(transport.synchronizedCount == 1)
    }

    @Test
    func testMissingRecordRetriesAreBounded() async {
        let local = makePreferences(style: .classic, time: 20, writer: "local")
        let transport = StatsPreferencesRecordTransportStub(
            fetchResult: .failure(StatsPreferencesRecordTransportTestError.missing)
        )
        transport.saveResults = Array(
            repeating: .failure(StatsPreferencesRecordTransportTestError.missing),
            count: StatsPreferencesCloudKitClient.maximumConflictAttempts
        )
        let client = StatsPreferencesCloudKitClient(transport: transport)

        do {
            _ = try await client.syncStatsPreferences(local)
            Issue.record("Expected bounded retry failure")
        } catch {
            #expect(error as? StatsPreferencesCloudClientError == .conflictRetryLimitReached)
        }

        #expect(
            transport.savedRecords.count
                == StatsPreferencesCloudKitClient.maximumConflictAttempts
        )
        #expect(transport.synchronizedCount == 0)
    }

    @Test
    func testUnclassifiedFailureIsNotRetried() async {
        let local = makePreferences(style: .classic, time: 20, writer: "local")
        let transport = StatsPreferencesRecordTransportStub(
            fetchResult: .failure(StatsPreferencesRecordTransportTestError.failed)
        )
        let client = StatsPreferencesCloudKitClient(transport: transport)

        do {
            _ = try await client.syncStatsPreferences(local)
            Issue.record("Expected transport failure")
        } catch {
            guard error as? StatsPreferencesRecordTransportTestError == .failed else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(transport.savedRecords.isEmpty)
        #expect(transport.synchronizedCount == 0)
    }

    private func record(for preferences: StatsPreferences) throws -> CKRecord {
        try StatsPreferencesCloudKitRecordCodec.record(
            for: preferences,
            recordID: StatsPreferencesCloudKitRecordCodec.recordID(
                in: CKRecordZone.ID(
                    zoneName: "StatsPreferencesClientTests",
                    ownerName: CKCurrentUserDefaultName
                )
            )
        )
    }

    private func makePreferences(
        style: StatsPreferences.Style,
        time: TimeInterval,
        writer: String
    ) -> StatsPreferences {
        StatsPreferences(
            style: style,
            blocks: StatsPreferences.defaultBlocks,
            updatedAt: Date(timeIntervalSince1970: time),
            lastWriterDeviceId: writer
        )
    }
}
