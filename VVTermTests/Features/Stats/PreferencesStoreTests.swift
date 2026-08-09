import XCTest
@testable import VVTerm

@MainActor
final class PreferencesStoreTests: XCTestCase {
    private var previousSyncSetting: Any?
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        previousSyncSetting = UserDefaults.standard.object(forKey: SyncSettings.enabledKey)
        UserDefaults.standard.set(false, forKey: SyncSettings.enabledKey)
        suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        if let previousSyncSetting {
            UserDefaults.standard.set(previousSyncSetting, forKey: SyncSettings.enabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SyncSettings.enabledKey)
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        previousSyncSetting = nil
        super.tearDown()
    }

    func testDefaultPreferencesReceiveApplicationWriterIdentity() {
        let store = PreferencesStore(defaults: defaults)

        XCTAssertEqual(store.preferences.lastWriterDeviceId, DeviceIdentity.id)
        XCTAssertNotNil(defaults.data(forKey: PreferencesStore.defaultsKey))
    }

    func testLegacyEmptyWriterReceivesApplicationWriterIdentity() throws {
        let legacy = StatsPreferences(
            style: .cardsDetailed,
            blocks: StatsPreferences.defaultBlocks,
            updatedAt: .distantPast,
            lastWriterDeviceId: ""
        )
        defaults.set(
            try JSONEncoder().encode(legacy),
            forKey: PreferencesStore.defaultsKey
        )

        let store = PreferencesStore(defaults: defaults)

        XCTAssertEqual(store.preferences.lastWriterDeviceId, DeviceIdentity.id)
    }
}
