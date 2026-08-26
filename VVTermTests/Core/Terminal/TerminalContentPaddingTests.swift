import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct TerminalContentPaddingTests {
    @Test
    func missingValuesUseZeroWithoutCreatingStoredPreferences() throws {
        let suiteName = "TerminalContentPaddingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(TerminalDefaults.storedContentPadding(defaults: defaults) == .defaultValue)

        TerminalDefaults.applyIfNeeded(defaults: defaults)

        #expect(defaults.object(forKey: TerminalDefaults.contentPaddingHorizontalKey) == nil)
        #expect(defaults.object(forKey: TerminalDefaults.contentPaddingVerticalKey) == nil)
    }

    @Test
    func valuesRoundAndClampToSupportedPoints() {
        let padding = TerminalContentPadding(horizontal: -8, vertical: 40.8)
        let rounded = TerminalContentPadding(horizontal: 7.6, vertical: 14.4)

        #expect(padding.horizontal == 0)
        #expect(padding.vertical == 32)
        #expect(rounded.horizontal == 8)
        #expect(rounded.vertical == 14)
    }

    @Test
    func nonFiniteAndExtremeValuesResolveWithoutOverflow() {
        #expect(TerminalContentPadding(horizontal: .nan, vertical: .infinity) == .defaultValue)
        #expect(
            TerminalContentPadding(
                horizontal: -.infinity,
                vertical: .greatestFiniteMagnitude
            ) == TerminalContentPadding(horizontal: 0, vertical: 32)
        )
    }

    @Test
    func storedInvalidValuesAreReplacedWithSafeValues() throws {
        let suiteName = "TerminalContentPaddingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(48.2, forKey: TerminalDefaults.contentPaddingHorizontalKey)
        defaults.set(true, forKey: TerminalDefaults.contentPaddingVerticalKey)

        TerminalDefaults.applyIfNeeded(defaults: defaults)

        #expect(defaults.double(forKey: TerminalDefaults.contentPaddingHorizontalKey) == 32)
        #expect(defaults.double(forKey: TerminalDefaults.contentPaddingVerticalKey) == 0)
        #expect(
            TerminalDefaults.storedContentPadding(defaults: defaults)
                == TerminalContentPadding(horizontal: 32, vertical: 0)
        )
    }
}
