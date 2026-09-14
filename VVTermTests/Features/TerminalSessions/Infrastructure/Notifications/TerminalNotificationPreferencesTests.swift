import Foundation
import Testing
@testable import VVTerm

struct TerminalNotificationPreferencesTests {
    @Test
    func preferenceDefaultsToEnabledAndPersistsBothSwitchValues() throws {
        let suite = "terminal-notifications-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(TerminalNotificationPreferences.isEnabled(in: defaults))
        for enabled in [false, true] {
            defaults.set(enabled, forKey: TerminalNotificationPreferences.enabledKey)
            let reopened = try #require(UserDefaults(suiteName: suite))
            #expect(TerminalNotificationPreferences.isEnabled(in: reopened) == enabled)
        }
    }
}
