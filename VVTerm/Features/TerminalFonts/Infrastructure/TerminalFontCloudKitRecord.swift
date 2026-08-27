import CloudKit
import Foundation

nonisolated enum TerminalFontCloudKitRecordCodec {
    static let recordType = "TerminalFont"
    static let assetKey = "asset"
    static let metadataKeys = [
        "familyNames",
        "originalFilename",
        "fileSize",
        "updatedAt",
        "deletedAt"
    ]

    static func font(from record: CKRecord) -> TerminalFont? {
        guard let familyNames = record["familyNames"] as? [String],
              let originalFilename = record["originalFilename"] as? String,
              let fileSize = (record["fileSize"] as? NSNumber)?.int64Value else {
            return nil
        }

        guard let font = try? TerminalFontValidator.validateStoredFont(
            TerminalFont(
                familyNames: familyNames,
                originalFilename: originalFilename,
                fileSize: fileSize,
                sha256: record.recordID.recordName,
                updatedAt: record["updatedAt"] as? Date ?? .distantPast,
                deletedAt: record["deletedAt"] as? Date
            )
        ) else {
            return nil
        }
        return font
    }

    static func assetURL(from record: CKRecord) -> URL? {
        (record[assetKey] as? CKAsset)?.fileURL
    }

    static func record(
        for font: TerminalFont,
        assetURL: URL?,
        in zoneID: CKRecordZone.ID
    ) -> CKRecord {
        let record = CKRecord(
            recordType: recordType,
            recordID: CKRecord.ID(recordName: font.id, zoneID: zoneID)
        )
        record["familyNames"] = font.familyNames
        record["originalFilename"] = font.originalFilename
        record["fileSize"] = NSNumber(value: font.fileSize)
        record["updatedAt"] = font.updatedAt
        record["deletedAt"] = font.deletedAt
        if let assetURL, !font.isDeleted {
            record[assetKey] = CKAsset(fileURL: assetURL)
        } else {
            // Mark the field as changed so `.changedKeys` removes an old asset.
            record[assetKey] = nil
        }
        return record
    }
}

nonisolated enum TerminalFontPreferenceCloudKitRecordCodec {
    static let recordType = "TerminalFontPreference"
    static let recordName = "terminal-font-preference.v1"

    static func preference(from record: CKRecord) -> TerminalFontPreference? {
        guard let primaryFamily = record["primaryFamilyName"] as? String else {
            return nil
        }
        return try? TerminalFontValidator.validatePreference(
            TerminalFontPreference(
                primaryFamily: primaryFamily,
                cjkFamily: record["cjkFamilyName"] as? String,
                updatedAt: record["updatedAt"] as? Date ?? .distantPast
            )
        )
    }

    static func recordID(in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: zoneID)
    }

    static func record(
        for preference: TerminalFontPreference,
        in zoneID: CKRecordZone.ID
    ) -> CKRecord {
        let record = CKRecord(
            recordType: recordType,
            recordID: recordID(in: zoneID)
        )
        record["primaryFamilyName"] = preference.primaryFamily
        record["cjkFamilyName"] = preference.cjkFamily
        record["updatedAt"] = preference.updatedAt
        return record
    }
}
