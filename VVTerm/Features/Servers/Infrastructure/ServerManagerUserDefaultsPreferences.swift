import Foundation

@MainActor
final class ServerManagerUserDefaultsPreferences: ServerManagerPreferences {
    // Keep this key value so current installs do not repeat initial setup.
    static let hasResolvedInitialWorkspaceKey = "com.vivy.vvterm.didBootstrapDefaultWorkspace"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var hasResolvedInitialWorkspace: Bool {
        get { defaults.bool(forKey: Self.hasResolvedInitialWorkspaceKey) }
        set { defaults.set(newValue, forKey: Self.hasResolvedInitialWorkspaceKey) }
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
}
