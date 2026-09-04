import Foundation

@MainActor
protocol TerminalFloatingControlPreferencesRepository: AnyObject {
    func load() -> TerminalFloatingControlPreferences
    func save(_ preferences: TerminalFloatingControlPreferences)
}
