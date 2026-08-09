import Foundation

enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case system
    case mlxWhisper
    case mlxParakeet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return String(localized: "System (Apple Speech)")
        case .mlxWhisper:
            return String(localized: "MLX Whisper")
        case .mlxParakeet:
            return String(localized: "MLX Parakeet")
        }
    }
}

struct TranscriptionSettingsKeys {
    static let provider = "transcriptionProvider"
    static let mlxWhisperModelId = "mlxWhisperModelId"
    static let mlxParakeetModelId = "mlxParakeetModelId"
    static let language = "transcriptionLanguage"
}

struct TranscriptionSettingsDefaults {
    static let provider: TranscriptionProvider = .system
    static let mlxWhisperModelId = MLXModelCatalog.defaultModelID(for: .whisper)
    static let mlxParakeetModelId = MLXModelCatalog.defaultModelID(for: .parakeetTDT)
    static let language = "en"
    static let autoLanguageCode = "auto"
}

struct TranscriptionSettingsStore {
    static func currentProvider() -> TranscriptionProvider {
        guard let raw = UserDefaults.standard.string(forKey: TranscriptionSettingsKeys.provider) else {
            return TranscriptionSettingsDefaults.provider
        }
        if let provider = TranscriptionProvider(rawValue: raw) {
            return provider
        }
        switch raw {
        case "whisper":
            return .mlxWhisper
        case "parakeet":
            return .mlxParakeet
        default:
            return TranscriptionSettingsDefaults.provider
        }
    }

    static func currentWhisperModelId() -> String {
        let raw: String
        if let modelId = UserDefaults.standard.string(forKey: TranscriptionSettingsKeys.mlxWhisperModelId) {
            raw = modelId
        } else if let legacy = UserDefaults.standard.string(forKey: "whisperModelId") {
            raw = legacy
        } else {
            raw = TranscriptionSettingsDefaults.mlxWhisperModelId
        }
        let resolution = MLXModelLegacyMigration.resolveModelID(raw, kind: .whisper)
        if case .migrated = resolution {
            UserDefaults.standard.set(
                resolution.modelID,
                forKey: TranscriptionSettingsKeys.mlxWhisperModelId
            )
            UserDefaults.standard.removeObject(forKey: "whisperModelId")
        }
        return resolution.modelID
    }

    static func currentLanguageCode() -> String {
        let raw = UserDefaults.standard.string(forKey: TranscriptionSettingsKeys.language)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let raw, !raw.isEmpty else { return TranscriptionSettingsDefaults.language }
        return raw
    }

    static func currentParakeetModelId() -> String {
        if let modelId = UserDefaults.standard.string(forKey: TranscriptionSettingsKeys.mlxParakeetModelId) {
            return modelId
        }
        if let legacy = UserDefaults.standard.string(forKey: "parakeetModelId") {
            return legacy
        }
        return TranscriptionSettingsDefaults.mlxParakeetModelId
    }

}
