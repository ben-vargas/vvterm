import XCTest
@testable import VVTerm

@MainActor
final class ViewTabConfigurationManagerTests: XCTestCase {
    private let legacyKeys = [
        "connectionViewTabOrder",
        "connectionDefaultViewTab",
        "showStatsTab",
        "showTerminalTab",
        "showFilesTab"
    ]

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "VVTermTests.ViewTabConfiguration.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func persistedConfiguration(in defaults: UserDefaults) throws -> ConnectionViewTabConfiguration {
        let data = try XCTUnwrap(defaults.data(forKey: ViewTabConfigurationManager.configurationKey))
        return try JSONDecoder().decode(ConnectionViewTabConfiguration.self, from: data)
    }

    func testHiddenDefaultFallsBackToFirstVisibleTab() {
        let manager = ViewTabConfigurationManager(defaults: makeDefaults())
        manager.setDefaultTab(.terminal)
        manager.setVisibility(for: .terminal, isVisible: false)

        XCTAssertEqual(manager.effectiveDefaultTab(), .stats)
        XCTAssertEqual(manager.configuration.defaultTab, .terminal)
    }

    func testCannotHideLastVisibleTab() {
        let manager = ViewTabConfigurationManager(defaults: makeDefaults())
        manager.setVisibility(for: .terminal, isVisible: false)
        manager.setVisibility(for: .files, isVisible: false)
        manager.setVisibility(for: .stats, isVisible: false)

        XCTAssertTrue(manager.isTabVisible(.stats))
        XCTAssertEqual(manager.currentVisibleTabs, [.stats])
    }

    func testLegacyKeysMigrateToOneConfigurationSnapshotAndAreRemoved() throws {
        let defaults = makeDefaults()
        defaults.set(
            try JSONEncoder().encode(["files", "unknown", "files", "stats"]),
            forKey: "connectionViewTabOrder"
        )
        defaults.set("terminal", forKey: "connectionDefaultViewTab")
        defaults.set(false, forKey: "showStatsTab")
        defaults.set(true, forKey: "showTerminalTab")
        defaults.set(false, forKey: "showFilesTab")

        let manager = ViewTabConfigurationManager(defaults: defaults)

        XCTAssertEqual(manager.tabOrder, [.files, .stats, .terminal])
        XCTAssertEqual(manager.configuration.visibleTabs, [.terminal])
        XCTAssertEqual(manager.configuration.defaultTab, .terminal)
        XCTAssertEqual(try persistedConfiguration(in: defaults), manager.configuration)
        for key in legacyKeys {
            XCTAssertNil(defaults.object(forKey: key))
        }
    }

    func testStoredConfigurationWinsOverStaleLegacyKeys() throws {
        let defaults = makeDefaults()
        let storedConfiguration = ConnectionViewTabConfiguration(
            order: [.terminal, .files, .stats],
            visibleTabs: [.terminal, .files],
            defaultTab: .files
        )
        defaults.set(
            try JSONEncoder().encode(storedConfiguration),
            forKey: ViewTabConfigurationManager.configurationKey
        )
        defaults.set("stats", forKey: "connectionDefaultViewTab")
        defaults.set(false, forKey: "showFilesTab")

        let manager = ViewTabConfigurationManager(defaults: defaults)

        XCTAssertEqual(manager.configuration, storedConfiguration)
        for key in legacyKeys {
            XCTAssertNil(defaults.object(forKey: key))
        }
    }

    func testEachMutationPersistsTheCompleteConfiguration() throws {
        let defaults = makeDefaults()
        let manager = ViewTabConfigurationManager(defaults: defaults)

        manager.setDefaultTab(.files)
        XCTAssertEqual(try persistedConfiguration(in: defaults), manager.configuration)

        manager.setVisibility(for: .stats, isVisible: false)
        XCTAssertEqual(try persistedConfiguration(in: defaults), manager.configuration)

        manager.moveTab(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(try persistedConfiguration(in: defaults), manager.configuration)

        let storedConfiguration = try persistedConfiguration(in: defaults)
        XCTAssertEqual(storedConfiguration, manager.configuration)
        XCTAssertEqual(storedConfiguration.order, [.files, .stats, .terminal])
        XCTAssertEqual(storedConfiguration.visibleTabs, [.terminal, .files])
        XCTAssertEqual(storedConfiguration.defaultTab, .files)
    }

    func testResetPersistsOnlyTheDefaultConfigurationSnapshot() throws {
        let defaults = makeDefaults()
        let manager = ViewTabConfigurationManager(defaults: defaults)
        manager.setDefaultTab(.files)
        manager.setVisibility(for: .stats, isVisible: false)

        manager.resetToDefaults()

        XCTAssertEqual(try persistedConfiguration(in: defaults), .default)
        for key in legacyKeys {
            XCTAssertNil(defaults.object(forKey: key))
        }
    }
}
