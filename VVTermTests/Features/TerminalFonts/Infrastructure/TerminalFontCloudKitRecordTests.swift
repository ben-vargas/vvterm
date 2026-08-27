import CloudKit
import Foundation
import Testing
@testable import VVTerm

struct TerminalFontCloudKitRecordTests {
    @Test
    func fontAndPreferenceRoundTrip() throws {
        let zoneID = CKRecordZone.ID(
            zoneName: "TerminalFontTests",
            ownerName: CKCurrentUserDefaultName
        )
        let font = TerminalFont(
            familyNames: ["Round Trip Font"],
            originalFilename: "RoundTrip.otf",
            fileSize: 2_048,
            sha256: String(repeating: "b", count: 64),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let preference = TerminalFontPreference(
            primaryFamily: font.displayName,
            cjkFamily: nil,
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let fontRecord = TerminalFontCloudKitRecordCodec.record(
            for: font,
            assetURL: URL(fileURLWithPath: "/font.otf"),
            in: zoneID
        )
        let preferenceRecord = TerminalFontPreferenceCloudKitRecordCodec.record(
            for: preference,
            in: zoneID
        )

        #expect(TerminalFontCloudKitRecordCodec.font(from: fontRecord) == font)
        #expect(TerminalFontCloudKitRecordCodec.assetURL(from: fontRecord)?.path == "/font.otf")
        #expect(fontRecord.recordID.zoneID == zoneID)
        #expect(
            TerminalFontPreferenceCloudKitRecordCodec.preference(from: preferenceRecord)
                == preference
        )
        #expect(
            preferenceRecord.recordID.recordName
                == TerminalFontPreferenceCloudKitRecordCodec.recordName
        )
    }

    @Test
    func pendingPayloadPreservesFontAndRoutingIdentity() throws {
        let font = TerminalFont(
            familyNames: ["Queued Font"],
            originalFilename: "Queued.ttf",
            fileSize: 512,
            sha256: String(repeating: "c", count: 64)
        )

        let payload = try TerminalFontPendingCloudKitPayloadCodec.encodeFont(font)

        #expect(try TerminalFontPendingCloudKitPayloadCodec.decodeFont(payload) == font)
        #expect(payload.coalescingKey == "terminalFont:\(font.id)")
    }

    @Test
    func tombstoneMarksTheAssetForRemoval() {
        let zoneID = CKRecordZone.ID(
            zoneName: "TerminalFontTests",
            ownerName: CKCurrentUserDefaultName
        )
        var font = TerminalFont(
            familyNames: ["Deleted Font"],
            originalFilename: "Deleted.ttf",
            fileSize: 512,
            sha256: String(repeating: "d", count: 64),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        font.deletedAt = font.updatedAt

        let record = TerminalFontCloudKitRecordCodec.record(
            for: font,
            assetURL: nil,
            in: zoneID
        )

        #expect(record[TerminalFontCloudKitRecordCodec.assetKey] == nil)
        #expect(record.changedKeys().contains(TerminalFontCloudKitRecordCodec.assetKey))
    }

    @Test
    func pendingPayloadRejectsInvalidPreferenceNames() throws {
        let preference = TerminalFontPreference(
            primaryFamily: String(repeating: "a", count: 257),
            cjkFamily: nil,
            updatedAt: Date()
        )
        let payload = try TerminalFontPendingCloudKitPayloadCodec.encodePreference(preference)

        #expect(throws: TerminalFontValidationError.invalidMetadata) {
            _ = try TerminalFontPendingCloudKitPayloadCodec.decodePreference(payload)
        }
    }
}
