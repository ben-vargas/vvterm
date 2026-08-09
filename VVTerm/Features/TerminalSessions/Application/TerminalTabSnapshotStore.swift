import Foundation

@MainActor
protocol TerminalTabSnapshotStoring: AnyObject {
    func loadSnapshotData() -> Data?
    func saveSnapshotData(_ data: Data)
    func removeSnapshotData()
}

@MainActor
final class UserDefaultsTerminalTabSnapshotStore: TerminalTabSnapshotStoring {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func loadSnapshotData() -> Data? {
        defaults.data(forKey: key)
    }

    func saveSnapshotData(_ data: Data) {
        defaults.set(data, forKey: key)
    }

    func removeSnapshotData() {
        defaults.removeObject(forKey: key)
    }
}
