import XCTest
@testable import VVTerm

@MainActor
final class TerminalAccessoryPreferencesManagerTests: XCTestCase {
    private var syncWasEnabledObject: Any?
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        syncWasEnabledObject = UserDefaults.standard.object(forKey: SyncSettings.enabledKey)
        UserDefaults.standard.set(false, forKey: SyncSettings.enabledKey)

        defaultsSuiteName = "TerminalAccessoryPreferencesManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        if let syncWasEnabledObject {
            UserDefaults.standard.set(syncWasEnabledObject, forKey: SyncSettings.enabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SyncSettings.enabledKey)
        }

        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        syncWasEnabledObject = nil
        super.tearDown()
    }

    func testCreateCustomActionPersistsAndUpdatesProfileMetadata() throws {
        let manager = TerminalAccessoryPreferencesManager(defaults: defaults)

        let action = try manager.createCustomAction(
            title: "List Files",
            kind: .command,
            commandContent: "ls -la",
            commandSendMode: .insertAndEnter,
            shortcutKey: .l,
            shortcutModifiers: .init(control: true)
        )

        XCTAssertEqual(manager.customActions.map(\.id), [action.id])
        XCTAssertEqual(manager.profile.lastWriterDeviceId, DeviceIdentity.id)
        XCTAssertEqual(manager.profile.customActions.first?.commandContent, "ls -la")
        XCTAssertNotNil(defaults.data(forKey: TerminalAccessoryPreferencesManager.defaultsKey))
    }

    func testResetToDefaultLayoutRestoresActiveItems() {
        let manager = TerminalAccessoryPreferencesManager(defaults: defaults)
        manager.removeActiveItem(.system(.escape))

        XCTAssertNotEqual(manager.activeItems, TerminalAccessoryProfile.defaultActiveItems)

        manager.resetToDefaultLayout()

        XCTAssertEqual(manager.activeItems, TerminalAccessoryProfile.defaultActiveItems)
        XCTAssertEqual(manager.profile.lastWriterDeviceId, DeviceIdentity.id)
    }

    func testLegacyProfileWithoutWriterReceivesApplicationWriterIdentity() throws {
        let profile = TerminalAccessoryProfile.defaultValue(lastWriterDeviceId: "legacy")
        let encoded = try JSONEncoder().encode(profile)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "lastWriterDeviceId")
        defaults.set(
            try JSONSerialization.data(withJSONObject: object),
            forKey: TerminalAccessoryPreferencesManager.defaultsKey
        )

        let manager = TerminalAccessoryPreferencesManager(defaults: defaults)

        XCTAssertEqual(manager.profile.lastWriterDeviceId, DeviceIdentity.id)
    }

    func testTypedCloudResolutionAppliesOnlyAccessoryProfile() {
        let resolutionHub = CloudKitSyncResolutionHub()
        let manager = TerminalAccessoryPreferencesManager(
            defaults: defaults,
            syncResolutionHub: resolutionHub
        )
        let updatedAt = Date()
        let remote = TerminalAccessoryProfile(
            schemaVersion: TerminalAccessoryProfile.schemaVersion,
            layout: TerminalAccessoryLayout(
                version: 1,
                activeItems: Array(TerminalAccessoryProfile.defaultActiveItems.reversed()),
                updatedAt: updatedAt
            ),
            customActions: [],
            updatedAt: updatedAt,
            lastWriterDeviceId: "remote"
        )

        resolutionHub.publish(.terminalAccessoryProfile(remote))

        XCTAssertEqual(manager.activeItems, Array(TerminalAccessoryProfile.defaultActiveItems.reversed()))
        XCTAssertEqual(manager.profile.lastWriterDeviceId, "remote")
    }
}
