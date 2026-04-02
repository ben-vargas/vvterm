import XCTest
@testable import VVTerm

final class TerminalPresetManagerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TerminalPresetManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAddPresetPersistsPreset() {
        let manager = TerminalPresetManager(defaults: defaults)

        manager.addPreset(name: "Claude", command: "claude", icon: "sparkles")

        XCTAssertEqual(manager.presets.count, 1)
        XCTAssertEqual(manager.presets.first?.name, "Claude")

        let reloaded = TerminalPresetManager(defaults: defaults)
        XCTAssertEqual(reloaded.presets.map(\.name), ["Claude"])
        XCTAssertEqual(reloaded.presets.first?.command, "claude")
        XCTAssertEqual(reloaded.presets.first?.icon, "sparkles")
    }

    func testUpdatePresetReplacesMatchingPreset() throws {
        let manager = TerminalPresetManager(defaults: defaults)
        manager.addPreset(name: "Claude", command: "claude", icon: "terminal")

        var updated = try XCTUnwrap(manager.presets.first)
        updated.name = "Claude Code"
        updated.command = "claude --continue"
        updated.icon = "chevron.left.forwardslash.chevron.right"

        manager.updatePreset(updated)

        XCTAssertEqual(manager.presets.count, 1)
        XCTAssertEqual(manager.presets.first?.name, "Claude Code")
        XCTAssertEqual(manager.presets.first?.command, "claude --continue")
        XCTAssertEqual(manager.presets.first?.icon, "chevron.left.forwardslash.chevron.right")
    }

    func testDeletePresetRemovesPreset() {
        let manager = TerminalPresetManager(defaults: defaults)
        manager.addPreset(name: "Claude", command: "claude")
        let presetID = try! XCTUnwrap(manager.presets.first?.id)

        manager.deletePreset(id: presetID)

        XCTAssertTrue(manager.presets.isEmpty)
    }
}
