import CloudKit
import Foundation

@MainActor
struct CloudKitZoneClient {
    private enum ResponseError: LocalizedError {
        case missingSavedZoneResult

        var errorDescription: String? {
            "CloudKit did not confirm the custom zone save."
        }
    }

    private let fetchZone: (CKRecordZone.ID) async throws -> CKRecordZone?
    private let saveZone: (CKRecordZone) async throws -> Void

    init(
        fetchZone: @escaping (CKRecordZone.ID) async throws -> CKRecordZone?,
        saveZone: @escaping (CKRecordZone) async throws -> Void
    ) {
        self.fetchZone = fetchZone
        self.saveZone = saveZone
    }

    func fetch(_ zoneID: CKRecordZone.ID) async throws -> CKRecordZone? {
        try await fetchZone(zoneID)
    }

    func save(_ zone: CKRecordZone) async throws {
        try await saveZone(zone)
    }

    static func live(database: CKDatabase) -> Self {
        Self(
            fetchZone: { zoneID in
                let results = try await database.recordZones(for: [zoneID])
                guard let result = results[zoneID] else { return nil }
                return try result.get()
            },
            saveZone: { zone in
                let results = try await database.modifyRecordZones(
                    saving: [zone],
                    deleting: []
                )
                guard let result = results.saveResults[zone.zoneID] else {
                    throw ResponseError.missingSavedZoneResult
                }
                _ = try result.get()
            }
        )
    }
}
