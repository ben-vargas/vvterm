import Foundation

@MainActor
final class UserDefaultsRemoteShellStartupActionRepository: RemoteShellStartupActionRepository {
    private static let storageKeyPrefix = "remoteShellStartupAction."

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func action(for serverID: UUID) -> RemoteShellStartupAction? {
        let key = Self.storageKey(for: serverID)
        guard let command = defaults.string(forKey: key) else {
            if defaults.object(forKey: key) != nil {
                defaults.removeObject(forKey: key)
            }
            return nil
        }
        do {
            return try RemoteShellStartupAction(command: command)
        } catch {
            defaults.removeObject(forKey: key)
            return nil
        }
    }

    func save(_ action: RemoteShellStartupAction?, for serverID: UUID) {
        let key = Self.storageKey(for: serverID)
        guard let action else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(action.command, forKey: key)
    }

    static func storageKey(for serverID: UUID) -> String {
        storageKeyPrefix + serverID.uuidString.lowercased()
    }
}
