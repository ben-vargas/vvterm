import Foundation
import Testing
@testable import VVTerm

@MainActor
struct ServerManagerUserDefaultsPreferencesTests {
    @Test
    func semanticPreferencesRoundTripWithoutExposingKeysToApplication() throws {
        let suiteName = "ServerManagerPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ServerManagerUserDefaultsPreferences(defaults: defaults)

        preferences.hasResolvedInitialWorkspace = true
        preferences.freePlanGeneration = .legacyThreeServers

        #expect(preferences.hasResolvedInitialWorkspace)
        #expect(preferences.freePlanGeneration == .legacyThreeServers)

        preferences.freePlanGeneration = nil
        #expect(preferences.freePlanGeneration == nil)
    }
}
