import CloudKit

@MainActor
protocol CloudKitRecordTransport: AnyObject {
    var cloudKitRecordZoneID: CKRecordZone.ID { get }

    func performCloudKitRecordMutation<T>(
        _ operation: () async throws -> T
    ) async throws -> T
    func fetchCloudKitRecords(
        matchingRecordTypes recordTypes: Set<String>,
        desiredKeys: [String]
    ) async throws -> [CKRecord]
    func fetchCloudKitRecord(_ recordID: CKRecord.ID) async throws -> CKRecord
    func upsertCloudKitRecord(_ record: CKRecord) async throws
    func saveCloudKitRecordIfUnchanged(_ record: CKRecord) async throws
    func markCloudKitRecordSynchronized()
    func cloudKitServerRecord(from error: Error) -> CKRecord?
    func isCloudKitRecordMissing(_ error: Error) -> Bool
}

extension CloudKitManager: CloudKitRecordTransport {}
