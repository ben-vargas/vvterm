import XCTest
@testable import VVTerm

@MainActor
final class UserDefaultsTerminalFloatingControlPreferencesRepositoryTests: XCTestCase {
    private let key = "test.floating-input-control"

    func testMissingValueUsesDefaultWithoutWriting() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        XCTAssertEqual(fixture.repository.load(), .defaultValue)
        XCTAssertNil(fixture.defaults.data(forKey: key))
    }

    func testInvalidValueIsRepairedWithDefault() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.defaults.set(
            try XCTUnwrap(#"{"style":"removed-style"}"#.data(using: .utf8)),
            forKey: key
        )

        XCTAssertEqual(fixture.repository.load(), .defaultValue)
        let repairedData = try XCTUnwrap(fixture.defaults.data(forKey: key))
        XCTAssertEqual(
            try JSONDecoder().decode(
                TerminalFloatingControlPreferences.self,
                from: repairedData
            ),
            .defaultValue
        )
    }

    func testLoadNormalizesAndRepairsSavedValue() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let raw = TerminalFloatingControlPreferences(
            style: .radial,
            compactActionLayout: .init(
                primaryAction: .voiceInput,
                secondaryActions: [.keyboard, .keyboard, .system(.escape)]
            ),
            radialActionLayout: .init(
                primaryAction: .system(.tab),
                secondaryActions: [
                    .system(.tab),
                    .voiceInput,
                    .keyboard,
                    .system(.escape),
                    .system(.arrowUp),
                    .system(.backspace),
                    .system(.arrowDown),
                    .system(.arrowLeft),
                    .system(.arrowRight),
                ]
            ),
            hiddenSide: .right,
            horizontalFraction: 2,
            verticalFraction: -2
        )
        fixture.defaults.set(try JSONEncoder().encode(raw), forKey: key)

        let loaded = fixture.repository.load()

        XCTAssertEqual(loaded.style, .radial)
        XCTAssertEqual(
            loaded.compactActionLayout,
            .init(
                primaryAction: .voiceInput,
                secondaryActions: [.keyboard, .system(.escape)]
            )
        )
        XCTAssertEqual(
            loaded.radialActionLayout,
            .init(
                primaryAction: .system(.tab),
                secondaryActions: [
                    .voiceInput,
                    .keyboard,
                    .system(.escape),
                    .system(.arrowUp),
                    .system(.backspace),
                    .system(.arrowDown),
                    .system(.arrowLeft),
                ]
            )
        )
        XCTAssertEqual(loaded.hiddenSide, .right)
        XCTAssertEqual(loaded.horizontalFraction, 1)
        XCTAssertEqual(loaded.verticalFraction, 0)
        let repairedData = try XCTUnwrap(fixture.defaults.data(forKey: key))
        XCTAssertEqual(
            try JSONDecoder().decode(
                TerminalFloatingControlPreferences.self,
                from: repairedData
            ),
            loaded
        )
    }

    private func makeFixture() throws -> (
        suiteName: String,
        defaults: UserDefaults,
        repository: UserDefaultsTerminalFloatingControlPreferencesRepository
    ) {
        let suiteName =
            "UserDefaultsTerminalFloatingControlPreferencesRepositoryTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (
            suiteName,
            defaults,
            UserDefaultsTerminalFloatingControlPreferencesRepository(
                defaults: defaults,
                key: key
            )
        )
    }
}
