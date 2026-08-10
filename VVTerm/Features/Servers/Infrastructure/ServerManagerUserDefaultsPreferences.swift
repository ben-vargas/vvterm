import Foundation

@MainActor
final class ServerManagerUserDefaultsPreferences: ServerManagerPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var didBootstrapDefaultWorkspace: Bool {
        get { defaults.bool(forKey: CloudKitSyncConstants.didBootstrapDefaultWorkspaceKey) }
        set { defaults.set(newValue, forKey: CloudKitSyncConstants.didBootstrapDefaultWorkspaceKey) }
    }

    var hasSeenWelcome: Bool {
        defaults.bool(forKey: "hasSeenWelcome")
    }

    var freePlanGeneration: FreePlanGeneration? {
        get {
            guard let rawValue = defaults.string(forKey: FreeTierLimits.planGenerationStorageKey) else {
                return nil
            }
            return FreePlanGeneration(rawValue: rawValue)
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: FreeTierLimits.planGenerationStorageKey)
            } else {
                defaults.removeObject(forKey: FreeTierLimits.planGenerationStorageKey)
            }
        }
    }

    var pendingBootstrapWorkspaceID: UUID? {
        get {
            guard let rawValue = defaults.string(
                forKey: CloudKitSyncConstants.pendingBootstrapWorkspaceIDKey
            ) else {
                return nil
            }
            return UUID(uuidString: rawValue)
        }
        set {
            if let newValue {
                defaults.set(
                    newValue.uuidString,
                    forKey: CloudKitSyncConstants.pendingBootstrapWorkspaceIDKey
                )
            } else {
                defaults.removeObject(forKey: CloudKitSyncConstants.pendingBootstrapWorkspaceIDKey)
            }
        }
    }
}
