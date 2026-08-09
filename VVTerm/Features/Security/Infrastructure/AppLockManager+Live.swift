import Foundation

extension AppLockManager {
    static let shared = AppLockManager()

    convenience init(
        defaults: UserDefaults = .standard,
        authService: any BiometricAuthServing = BiometricAuthService.shared,
        now: @escaping () -> Date = Date.init,
        makeID: @escaping () -> UUID = UUID.init
    ) {
        self.init(
            dependencies: AppLockManagerDependencies(
                preferences: UserDefaultsAppLockPreferences(defaults: defaults),
                authService: authService,
                now: now,
                makeID: makeID
            )
        )
    }
}
