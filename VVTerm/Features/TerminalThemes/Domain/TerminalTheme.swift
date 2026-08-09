//
//  TerminalTheme.swift
//  VVTerm
//

import Foundation
import CloudKit

nonisolated struct TerminalTheme: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var content: String
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        content: String,
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var isDeleted: Bool {
        deletedAt != nil
    }

    var validationState: TerminalThemeValidationState {
        do {
            let content = try TerminalThemeValidator.validateAndNormalizeThemeContent(content)
            _ = try TerminalThemeValidator.validateAndNormalizeThemeName(name)
            return .ready(normalizedContent: content)
        } catch {
            return .needsRepair(message: error.localizedDescription)
        }
    }

    var canApply: Bool {
        if case .ready = validationState { return true }
        return false
    }
}

nonisolated enum TerminalThemeValidationState: Equatable, Sendable {
    case ready(normalizedContent: String)
    case needsRepair(message: String)
}

nonisolated enum TerminalThemeMergePolicy {
    static func merge(local: [TerminalTheme], remote: [TerminalTheme]) -> [TerminalTheme] {
        var themesByID: [UUID: TerminalTheme] = [:]
        for theme in local {
            if let existing = themesByID[theme.id], existing.updatedAt >= theme.updatedAt {
                continue
            }
            themesByID[theme.id] = theme
        }

        for untrustedTheme in remote {
            guard let theme = try? TerminalThemeValidator.validateStoredTheme(untrustedTheme) else {
                continue
            }
            if let existing = themesByID[theme.id], existing.updatedAt >= theme.updatedAt {
                continue
            }
            themesByID[theme.id] = theme
        }
        return Array(themesByID.values)
    }
}

nonisolated struct TerminalThemePreference: Codable, Equatable, Sendable {
    static let recordName = "terminal-theme-preference.v1"

    var darkThemeName: String
    var lightThemeName: String
    var usePerAppearanceTheme: Bool
    var updatedAt: Date
}

// MARK: - CloudKit Serialization

extension TerminalTheme {
    init?(from record: CKRecord) {
        guard
            let id = UUID(uuidString: record.recordID.recordName),
            let name = record["name"] as? String,
            let content = record["content"] as? String,
            let validatedName = try? TerminalThemeValidator.validateAndNormalizeThemeName(name)
        else {
            return nil
        }

        self.id = id
        self.name = validatedName
        self.content = content
        self.updatedAt = record["updatedAt"] as? Date ?? Date.distantPast
        self.deletedAt = record["deletedAt"] as? Date
    }

    func toRecord(in zoneID: CKRecordZone.ID? = nil) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID ?? CKRecordZone.default().zoneID)
        let record = CKRecord(recordType: "TerminalTheme", recordID: recordID)
        record["name"] = name
        record["content"] = content
        record["updatedAt"] = updatedAt
        record["deletedAt"] = deletedAt
        return record
    }
}

extension TerminalThemePreference {
    init?(from record: CKRecord) {
        guard
            let darkThemeName = record["darkThemeName"] as? String,
            let lightThemeName = record["lightThemeName"] as? String,
            let usePerAppearanceTheme = record["usePerAppearanceTheme"] as? Int,
            let validatedDarkThemeName = try? TerminalThemeValidator.validateAndNormalizeThemeName(darkThemeName),
            let validatedLightThemeName = try? TerminalThemeValidator.validateAndNormalizeThemeName(lightThemeName)
        else {
            return nil
        }

        self.darkThemeName = validatedDarkThemeName
        self.lightThemeName = validatedLightThemeName
        self.usePerAppearanceTheme = usePerAppearanceTheme != 0
        self.updatedAt = record["updatedAt"] as? Date ?? Date.distantPast
    }

    func toRecord(in zoneID: CKRecordZone.ID? = nil) -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: Self.recordName,
            zoneID: zoneID ?? CKRecordZone.default().zoneID
        )
        let record = CKRecord(recordType: "TerminalThemePreference", recordID: recordID)
        record["darkThemeName"] = darkThemeName
        record["lightThemeName"] = lightThemeName
        record["usePerAppearanceTheme"] = usePerAppearanceTheme ? 1 : 0
        record["updatedAt"] = updatedAt
        return record
    }
}
