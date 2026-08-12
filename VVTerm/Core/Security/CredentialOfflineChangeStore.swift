import Foundation

nonisolated enum CredentialOfflineChange: String, Codable, Equatable, Sendable {
    case unchanged
    case updated
    case deleted
}

nonisolated enum CredentialReconciliationPhase: String, Codable, Equatable, Sendable {
    case remoteChanges
    case localCleanup
}

nonisolated enum CredentialSyncUnit: Hashable, Sendable {
    case server(UUID)
    case sshKey(UUID)
    case legacySSHLibrary
    case oauth(String)

    var storageKey: String {
        switch self {
        case .server(let id):
            return "server:\(id.uuidString)"
        case .sshKey(let id):
            return "ssh-key:\(id.uuidString)"
        case .legacySSHLibrary:
            return "ssh-library"
        case .oauth(let key):
            return "oauth:\(key)"
        }
    }

    fileprivate init?(storageKey: String) {
        if storageKey == "ssh-library" {
            self = .legacySSHLibrary
            return
        }
        if storageKey.hasPrefix("ssh-key:"),
           let id = UUID(uuidString: String(storageKey.dropFirst("ssh-key:".count))) {
            self = .sshKey(id)
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
    private static let phaseKey = "vvterm.keychain.offlineReconciliationPhase.v2"
    private static let changeDatesKey = "vvterm.keychain.offlineChangeDates.v2"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isTrackingOfflineChanges: Bool {
        reconciliationPhase != nil
    }

    var reconciliationPhase: CredentialReconciliationPhase? {
        withLock {
            if let rawValue = defaults.string(forKey: Self.phaseKey) {
                return CredentialReconciliationPhase(rawValue: rawValue)
            }
            return defaults.bool(forKey: Self.trackingKey) ? .remoteChanges : nil
        }
    }

    func beginOfflineTracking(units: Set<CredentialSyncUnit>) throws {
        try withLock {
            let values = Dictionary(
                uniqueKeysWithValues: units.map {
                    ($0.storageKey, CredentialOfflineChange.unchanged.rawValue)
                }
            )
            defaults.set(values, forKey: Self.stateKey)
            defaults.removeObject(forKey: Self.changeDatesKey)
            defaults.set(CredentialReconciliationPhase.remoteChanges.rawValue, forKey: Self.phaseKey)
            defaults.set(true, forKey: Self.trackingKey)
            try verify(values: values, phase: .remoteChanges)
        }
    }

    func record(_ change: CredentialOfflineChange, for unit: CredentialSyncUnit) throws {
        try withLock {
            var values = storedValues()
            values[unit.storageKey] = change.rawValue
            defaults.set(values, forKey: Self.stateKey)
            var dates = storedChangeDates()
            dates[unit.storageKey] = Date().timeIntervalSinceReferenceDate
            defaults.set(dates, forKey: Self.changeDatesKey)
            guard storedValues() == values,
                  storedChangeDates() == dates else {
                throw CredentialOfflineChangeStoreError.persistenceFailed
            }
        }
    }

    func change(for unit: CredentialSyncUnit) -> CredentialOfflineChange? {
        withLock {
            storedValues()[unit.storageKey].flatMap(CredentialOfflineChange.init(rawValue:))
        }
    }

    func changeDate(for unit: CredentialSyncUnit) -> Date? {
        withLock {
            storedChangeDates()[unit.storageKey].map(Date.init(timeIntervalSinceReferenceDate:))
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

    func markRemoteChangesApplied() throws {
        try withLock {
            defaults.set(CredentialReconciliationPhase.localCleanup.rawValue, forKey: Self.phaseKey)
            defaults.set(true, forKey: Self.trackingKey)
            try verify(values: storedValues(), phase: .localCleanup)
        }
    }

    func finishOnlineReconciliation() throws {
        try withLock {
            defaults.removeObject(forKey: Self.stateKey)
            defaults.removeObject(forKey: Self.phaseKey)
            defaults.removeObject(forKey: Self.changeDatesKey)
            defaults.set(false, forKey: Self.trackingKey)
            guard defaults.object(forKey: Self.stateKey) == nil,
                  defaults.object(forKey: Self.phaseKey) == nil,
                  defaults.object(forKey: Self.changeDatesKey) == nil,
                  !defaults.bool(forKey: Self.trackingKey) else {
                throw CredentialOfflineChangeStoreError.persistenceFailed
            }
        }
    }

    private func verify(
        values: [String: String],
        phase: CredentialReconciliationPhase
    ) throws {
        guard storedValues() == values,
              defaults.string(forKey: Self.phaseKey) == phase.rawValue,
              defaults.bool(forKey: Self.trackingKey) else {
            throw CredentialOfflineChangeStoreError.persistenceFailed
        }
    }

    private func storedValues() -> [String: String] {
        defaults.dictionary(forKey: Self.stateKey) as? [String: String] ?? [:]
    }

    private func storedChangeDates() -> [String: Double] {
        let values = defaults.dictionary(forKey: Self.changeDatesKey) ?? [:]
        return values.reduce(into: [:]) { result, element in
            if let number = element.value as? NSNumber {
                result[element.key] = number.doubleValue
            }
        }
    }

    private func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

nonisolated enum CredentialOfflineChangeStoreError: Error, Equatable, Sendable {
    case persistenceFailed
}

nonisolated enum CredentialSyncError: LocalizedError, Equatable, Sendable {
    case offlineReconciliationPending

    var errorDescription: String? {
        "Credential reconciliation must finish before iCloud credentials can be removed."
    }
}
