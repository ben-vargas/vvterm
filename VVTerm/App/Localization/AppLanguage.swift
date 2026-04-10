import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    static let storageKey = "appLanguage"

    case system = "system"
    case en = "en"
    case zhHans = "zh-Hans"
    case ja = "ja"
    case th = "th"
    case vi = "vi"
    case es = "es"
    case ru = "ru"
    case fr = "fr"
    case de = "de"
    case be = "be"
    case uk = "uk"
    case pl = "pl"
    case cs = "cs"
    case ko = "ko"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "System (Default)")
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .th: return "ไทย"
        case .vi: return "Tiếng Việt"
        case .es: return "Español"
        case .ru: return "Русский"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .be: return "Беларуская"
        case .uk: return "Українська"
        case .pl: return "Polski"
        case .cs: return "Čeština"
        }
    }

    var locale: Locale {
        if self == .system {
            return Locale.current
        }
        return Locale(identifier: rawValue)
    }

    static func applySelection(_ rawValue: String) {
        if rawValue == AppLanguage.system.rawValue {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }

    static func localizedString(_ key: String, rawValue: String? = UserDefaults.standard.string(forKey: storageKey)) -> String {
        localizationBundle(for: rawValue).localizedString(forKey: key, value: nil, table: nil)
    }

    static func localizedValues(for key: String) -> Set<String> {
        var values = Set(allCases.map { localizedString(key, rawValue: $0.rawValue) })
        values.insert(Bundle.main.localizedString(forKey: key, value: nil, table: nil))
        return values
    }

    private var localizationIdentifier: String? {
        switch self {
        case .system:
            return Self.preferredLocalizationIdentifier()
        default:
            return rawValue
        }
    }

    private static func localizationBundle(for rawValue: String?) -> Bundle {
        let selection = AppLanguage(rawValue: rawValue ?? AppLanguage.system.rawValue) ?? .system
        guard let identifier = selection.localizationIdentifier,
              let bundle = bundle(forLocalizationIdentifier: identifier) else {
            return .main
        }
        return bundle
    }

    private static func bundle(forLocalizationIdentifier identifier: String) -> Bundle? {
        guard let resolved = resolvedLocalizationIdentifier(for: identifier),
              let path = Bundle.main.path(forResource: resolved, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }

    private static func preferredLocalizationIdentifier() -> String? {
        let preferredLanguages = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages

        for identifier in preferredLanguages {
            if let resolved = resolvedLocalizationIdentifier(for: identifier) {
                return resolved
            }
        }

        return nil
    }

    private static func resolvedLocalizationIdentifier(for identifier: String) -> String? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        for candidate in localizationCandidates(for: normalized) {
            if Bundle.main.path(forResource: candidate, ofType: "lproj") != nil {
                return candidate
            }
        }
        return nil
    }

    private static func localizationCandidates(for identifier: String) -> [String] {
        var candidates: [String] = []

        func append(_ candidate: String?) {
            guard let candidate, !candidate.isEmpty, !candidates.contains(candidate) else {
                return
            }
            candidates.append(candidate)
        }

        append(identifier)

        let components = Locale.components(fromIdentifier: identifier)
        let languageCodeKey = NSLocale.Key.languageCode.rawValue
        let scriptCodeKey = NSLocale.Key.scriptCode.rawValue

        if let language = components[languageCodeKey] {
            if let script = components[scriptCodeKey] {
                append("\(language)-\(script)")
            }

            if language == "zh" {
                append("zh-Hans")
            }

            append(language)
        }

        return candidates
    }
}
