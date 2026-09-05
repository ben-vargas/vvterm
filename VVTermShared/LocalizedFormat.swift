import Foundation

/// Formats counts with the language of the bundled text, including when the app
/// language differs from the device language. Foundation selects the plural form.
nonisolated enum LocalizedFormat {
    static func string(_ key: String, _ arguments: CVarArg..., bundle: Bundle = .main) -> String {
        let language = bundle.preferredLocalizations.first ?? bundle.developmentLocalization ?? "en"
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        return String(format: format, locale: Locale(identifier: language), arguments: arguments)
    }
}
