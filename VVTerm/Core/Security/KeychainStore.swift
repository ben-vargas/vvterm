//
//  KeychainStore.swift
//  VVTerm
//
//  Device-only Keychain storage for credentials and other secrets.
//

import Foundation
import Security

final class KeychainStore: @unchecked Sendable {
    private let service: String

    nonisolated init(service: String) {
        self.service = service
    }

    // MARK: - Data Operations

    nonisolated func set(_ data: Data, forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        // Remove existing item if any
        var deleteQuery = query
        deleteQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(deleteQuery as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    nonisolated func get(_ key: String) throws -> Data? {
        if let data = try get(key, synchronizable: false) {
            try delete(key, synchronizable: true)
            return data
        }

        guard let synchronizedData = try get(key, synchronizable: true) else {
            return nil
        }

        // Move legacy synchronized items into device-only storage.
        try set(synchronizedData, forKey: key)
        return synchronizedData
    }

    private nonisolated func get(_ key: String, synchronizable: Bool) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue : kCFBooleanFalse
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }

        return item as? Data
    }

    nonisolated func contains(_ key: String) throws -> Bool {
        try get(key) != nil
    }

    nonisolated func delete(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny  // Delete both synced and non-synced
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    private nonisolated func delete(_ key: String, synchronizable: Bool) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue : kCFBooleanFalse
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    // MARK: - String Convenience

    nonisolated func setString(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try set(data, forKey: key)
    }

    nonisolated func getString(_ key: String) throws -> String? {
        guard let data = try get(key) else {
            return nil
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }
        return string
    }
}

// MARK: - Keychain Error

enum KeychainError: LocalizedError {
    case unhandled(OSStatus)
    case encodingFailed
    case decodingFailed
    case itemNotFound
    case credentialServerMismatch

    var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            return "Keychain error: \(status)"
        case .encodingFailed:
            return "Failed to encode data for keychain"
        case .decodingFailed:
            return "Failed to decode data from keychain"
        case .itemNotFound:
            return "Item not found in keychain"
        case .credentialServerMismatch:
            return "Credentials do not belong to this server"
        }
    }
}
