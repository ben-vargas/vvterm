import CloudKit
import Foundation
import Testing
@testable import VVTerm

private enum TerminalFontCloudKitClientTestError: Error {
    case missing
}

@MainActor
private final class TerminalFontRecordTransportStub: CloudKitRecordTransport {
    let cloudKitRecordZoneID = CKRecordZone.ID(
        zoneName: "TerminalFontClientTests",
        ownerName: CKCurrentUserDefaultName
    )

    var listedRecords: [CKRecord] = []
    var fetchedRecords: [CKRecord.ID: CKRecord] = [:]
    private(set) var requestedKeys: [String] = []
    private(set) var requestedRecordIDs: [CKRecord.ID] = []
    private(set) var upsertedRecords: [CKRecord] = []

    func performCloudKitRecordMutation<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try await operation()
    }

    func fetchCloudKitRecords(
        matchingRecordTypes recordTypes: Set<String>,
        desiredKeys: [String]
    ) async throws -> [CKRecord] {
        requestedKeys = desiredKeys
        return listedRecords
    }

    func fetchCloudKitRecord(_ recordID: CKRecord.ID) async throws -> CKRecord {
        requestedRecordIDs.append(recordID)
        guard let record = fetchedRecords[recordID] else {
            throw TerminalFontCloudKitClientTestError.missing
        }
        return record
    }

    func upsertCloudKitRecord(_ record: CKRecord) async throws {
        upsertedRecords.append(record)
    }

    func saveCloudKitRecordIfUnchanged(_ record: CKRecord) async throws {}
    func cloudKitServerRecord(from error: Error) -> CKRecord? { nil }

    func isCloudKitRecordMissing(_ error: Error) -> Bool {
        error is TerminalFontCloudKitClientTestError
    }
}

@MainActor
private final class TerminalFontAssetRepositoryStub: TerminalFontAssetRepository {
    var localURLs: [TerminalFont.ID: URL] = [:]
    private(set) var installedFontIDs: [TerminalFont.ID] = []

    func installRemoteAsset(from sourceURL: URL, for font: TerminalFont) throws {
        installedFontIDs.append(font.id)
        localURLs[font.id] = sourceURL
    }

    func existingFileURL(for font: TerminalFont) -> URL? {
        localURLs[font.id]
    }
}

@MainActor
struct TerminalFontCloudKitClientTests {
    @Test
    func downloadsOnlyMissingFontAssets() async throws {
        let transport = TerminalFontRecordTransportStub()
        let repository = TerminalFontAssetRepositoryStub()
        let font = makeFont()
        let metadataRecord = TerminalFontCloudKitRecordCodec.record(
            for: font,
            assetURL: nil,
            in: transport.cloudKitRecordZoneID
        )
        let assetURL = URL(fileURLWithPath: "/cloud/font.ttf")
        let assetRecord = TerminalFontCloudKitRecordCodec.record(
            for: font,
            assetURL: assetURL,
            in: transport.cloudKitRecordZoneID
        )
        transport.listedRecords = [metadataRecord]
        transport.fetchedRecords[metadataRecord.recordID] = assetRecord
        let client = TerminalFontCloudKitClient(
            transport: transport,
            repository: repository
        )

        let fonts = try await client.fetchTerminalFonts()

        #expect(fonts == [font])
        #expect(repository.installedFontIDs == [font.id])
        #expect(transport.requestedRecordIDs == [metadataRecord.recordID])
        #expect(transport.requestedKeys == TerminalFontCloudKitRecordCodec.metadataKeys)
        #expect(!transport.requestedKeys.contains(TerminalFontCloudKitRecordCodec.assetKey))
    }

    @Test
    func keepsExistingAssetWithoutDownloadingItAgain() async throws {
        let transport = TerminalFontRecordTransportStub()
        let repository = TerminalFontAssetRepositoryStub()
        let font = makeFont()
        repository.localURLs[font.id] = URL(fileURLWithPath: "/local/font.ttf")
        transport.listedRecords = [
            TerminalFontCloudKitRecordCodec.record(
                for: font,
                assetURL: nil,
                in: transport.cloudKitRecordZoneID
            )
        ]
        let client = TerminalFontCloudKitClient(
            transport: transport,
            repository: repository
        )

        let fonts = try await client.fetchTerminalFonts()

        #expect(fonts == [font])
        #expect(repository.installedFontIDs.isEmpty)
        #expect(transport.requestedRecordIDs.isEmpty)
    }

    private func makeFont() -> TerminalFont {
        TerminalFont(
            familyNames: ["Cloud Font"],
            originalFilename: "CloudFont.ttf",
            fileSize: 1_024,
            sha256: String(repeating: "a", count: 64),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }
}
