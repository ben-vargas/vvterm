import Foundation

nonisolated enum TerminalFontPendingCloudKitPayloadCodec {
    static let fontEntityType = "terminalFont"
    static let preferenceEntityType = "terminalFontPreference"
    private static let fontDrainPriority = 2
    private static let preferenceDrainPriority = 3

    static func encodeFont(_ font: TerminalFont) throws -> PendingCloudKitPayloadEnvelope {
        try PendingCloudKitPayloadEnvelope(
            entityType: fontEntityType,
            entityKey: font.id,
            operation: .upsert,
            drainPriority: fontDrainPriority,
            value: font
        )
    }

    static func encodePreference(
        _ preference: TerminalFontPreference
    ) throws -> PendingCloudKitPayloadEnvelope {
        try PendingCloudKitPayloadEnvelope(
            entityType: preferenceEntityType,
            entityKey: TerminalFontPreferenceCloudKitRecordCodec.recordName,
            operation: .upsert,
            drainPriority: preferenceDrainPriority,
            value: preference
        )
    }

    static func decodeFont(_ payload: PendingCloudKitPayloadEnvelope) throws -> TerminalFont? {
        guard let font = try payload.decode(
            TerminalFont.self,
            entityType: fontEntityType,
            operation: .upsert
        ) else {
            return nil
        }
        try payload.validate(entityKey: font.id, drainPriority: fontDrainPriority)
        return try TerminalFontValidator.validateStoredFont(font)
    }

    static func decodePreference(
        _ payload: PendingCloudKitPayloadEnvelope
    ) throws -> TerminalFontPreference? {
        guard let preference = try payload.decode(
            TerminalFontPreference.self,
            entityType: preferenceEntityType,
            operation: .upsert
        ) else {
            return nil
        }
        try payload.validate(
            entityKey: TerminalFontPreferenceCloudKitRecordCodec.recordName,
            drainPriority: preferenceDrainPriority
        )
        return try TerminalFontValidator.validatePreference(preference)
    }
}

nonisolated extension PendingCloudKitPayloadEnvelope {
    static func terminalFontUpsert(_ font: TerminalFont) throws -> Self {
        try TerminalFontPendingCloudKitPayloadCodec.encodeFont(font)
    }

    static func terminalFontPreferenceUpsert(_ preference: TerminalFontPreference) throws -> Self {
        try TerminalFontPendingCloudKitPayloadCodec.encodePreference(preference)
    }
}
