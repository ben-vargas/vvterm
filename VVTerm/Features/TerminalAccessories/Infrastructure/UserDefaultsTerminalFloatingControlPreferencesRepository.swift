import Foundation
import os.log

@MainActor
final class UserDefaultsTerminalFloatingControlPreferencesRepository:
    TerminalFloatingControlPreferencesRepository
{
    static let storageKey = "vvterm.terminal.floatingInputControl.preferences"

    private let defaults: UserDefaults
    private let key: String
    private let logger = Logger(
        subsystem: "app.vivy.vvterm",
        category: "TerminalFloatingControlPreferences"
    )

    init(defaults: UserDefaults, key: String = storageKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> TerminalFloatingControlPreferences {
        guard let data = defaults.data(forKey: key) else {
            return .defaultValue
        }

        do {
            let decoded = try JSONDecoder().decode(
                TerminalFloatingControlPreferences.self,
                from: data
            )
            let normalized = decoded.normalized()
            if normalized != decoded {
                save(normalized)
            }
            return normalized
        } catch {
            logger.error(
                "Failed to decode floating control preferences: \(error.localizedDescription)"
            )
            return replaceWithDefaultPreferences()
        }
    }

    func save(_ preferences: TerminalFloatingControlPreferences) {
        do {
            defaults.set(
                try JSONEncoder().encode(preferences.normalized()),
                forKey: key
            )
        } catch {
            logger.error(
                "Failed to encode floating control preferences: \(error.localizedDescription)"
            )
        }
    }

    private func replaceWithDefaultPreferences() -> TerminalFloatingControlPreferences {
        let preferences = TerminalFloatingControlPreferences.defaultValue
        save(preferences)
        return preferences
    }
}
