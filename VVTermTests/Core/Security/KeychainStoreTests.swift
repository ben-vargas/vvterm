import Security
import XCTest
@testable import VVTerm

final class KeychainStoreTests: XCTestCase {
    private var service = ""
    private var key = ""
    private var store: KeychainStore!

    override func setUp() {
        super.setUp()
        service = "app.vivy.vvterm.tests.\(UUID().uuidString)"
        key = UUID().uuidString
        store = KeychainStore(service: service)
    }

    override func tearDown() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(query as CFDictionary)
        store = nil
        super.tearDown()
    }

    func testSetStoresDeviceOnlyItem() throws {
        let expected = Data("secret".utf8)

        try store.set(expected, forKey: key)

        let local = copyItem(synchronizable: false)
        XCTAssertEqual(local.status, errSecSuccess)
        XCTAssertEqual(local.data, expected)
        XCTAssertEqual(copyItem(synchronizable: true).status, errSecItemNotFound)
    }

    func testGetMigratesLegacySynchronizedItemToDeviceOnlyStorage() throws {
        let expected = Data("legacy-secret".utf8)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: expected,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecMissingEntitlement || addStatus == errSecNotAvailable {
            throw XCTSkip("Synchronized Keychain items are unavailable in this test environment")
        }
        XCTAssertEqual(addStatus, errSecSuccess)

        XCTAssertEqual(try store.get(key), expected)
        XCTAssertEqual(copyItem(synchronizable: true).status, errSecItemNotFound)

        let local = copyItem(synchronizable: false)
        XCTAssertEqual(local.status, errSecSuccess)
        XCTAssertEqual(local.data, expected)
    }

    private func copyItem(synchronizable: Bool) -> (status: OSStatus, data: Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue : kCFBooleanFalse,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let attributes = item as? [String: Any]
        return (status, attributes?[kSecValueData as String] as? Data)
    }
}
