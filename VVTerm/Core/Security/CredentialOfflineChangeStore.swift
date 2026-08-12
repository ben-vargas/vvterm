import Foundation

nonisolated enum CredentialOfflineChange: String, Codable, Equatable, Sendable {
    case unchanged
    case updated
    case deleted
}

nonisolated enum CredentialSyncUnit: Hashable, Sendable {
    case server(UUID)
    case sshLibrary
    case oauth(String)

    fileprivate var storageKey: String {
        switch self {
        case .server(let id):
            return "server:\(id.uuidString)"
        case .sshLibrary:
            return "ssh-library"
        case .oauth(let key):
            return "oauth:\(key)"
        }
    }

    fileprivate init?(storageKey: String) {
        if storageKey == "ssh-library" {
            self = .sshLibrary
            return
        }
        if storageKey.hasPrefix("server:"),
           let id = UUID(uuidString: String(storageKey.dropFirst("server:".count))) {
            self = .server(id)
            return
        }
        if storageKey.hasPrefix("oauth:") {
            self = .oauth(String(storageKey.dropFirst("oauth:".count)))
            return
        }
        return nil
    }
}

nonisolated final class CredentialOfflineChangeStore: @unchecked Sendable {
    static let shared = CredentialOfflineChangeStore()

    private static let stateKey = "vvterm.keychain.offlineChanges.v1"
    private static let trackingKey = "vvterm.keychain.offlineTracking.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isTrackingOfflineChanges: Bool {
        withLock { defaults.bool(forKey: Self.trackingKey) }
    }

    func beginOfflineTracking(units: Set<CredentialSyncUnit>) {
        withLock {
            defaults.set(
                Dictionary(
                    uniqueKeysWithValues: units.map {
                        ($0.storageKey, CredentialOfflineChange.unchanged.rawValue)
                    }
                ),
                forKey: Self.stateKey
            )
            defaults.set(true, forKey: Self.trackingKey)
        }
    }

    func record(_ change: CredentialOfflineChange, for unit: CredentialSyncUnit) {
        withLock {
            var values = storedValues()
            values[unit.storageKey] = change.rawValue
            defaults.set(values, forKey: Self.stateKey)
        }
    }

    func change(for unit: CredentialSyncUnit) -> CredentialOfflineChange? {
        withLock {
            storedValues()[unit.storageKey].flatMap(CredentialOfflineChange.init(rawValue:))
        }
    }

    func clearChange(for unit: CredentialSyncUnit) {
        withLock {
            var values = storedValues()
            values[unit.storageKey] = nil
            defaults.set(values, forKey: Self.stateKey)
        }
    }

    func snapshot() -> [CredentialSyncUnit: CredentialOfflineChange] {
        withLock {
            Dictionary(
                uniqueKeysWithValues: storedValues().compactMap { key, value in
                    guard let unit = CredentialSyncUnit(storageKey: key),
                          let change = CredentialOfflineChange(rawValue: value) else {
                        return nil
                    }
                    return (unit, change)
                }
            )
        }
    }

    func finishOnlineReconciliation() {
        withLock {
            defaults.removeObject(forKey: Self.stateKey)
            defaults.set(false, forKey: Self.trackingKey)
        }
    }

    private func storedValues() -> [String: String] {
        defaults.dictionary(forKey: Self.stateKey) as? [String: String] ?? [:]
    }

    private func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
