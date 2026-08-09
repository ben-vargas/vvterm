import Foundation
import Combine

@MainActor
final class AppLockManager: ObservableObject {
    private enum Keys {
        static let fullAppLockEnabled = "security.fullAppLockEnabled"
        static let lockOnBackground = "security.lockOnBackground"
        static let authGraceSeconds = "security.authGraceSeconds"
    }

    @Published private(set) var lockState: AppLockState
    @Published private(set) var authenticationState: AppLockAuthenticationState = .idle
    @Published private(set) var lastFailure: AppLockFailure?
    @Published private(set) var biometricAvailability: BiometricAvailability

    @Published private(set) var fullAppLockEnabled: Bool {
        didSet {
            defaults.set(fullAppLockEnabled, forKey: Keys.fullAppLockEnabled)
            if !fullAppLockEnabled {
                invalidateAuthentication()
                unlockedServers.removeAll()
                lockState = .unlocked(at: nil)
            }
        }
    }

    @Published var lockOnBackground: Bool {
        didSet {
            defaults.set(lockOnBackground, forKey: Keys.lockOnBackground)
        }
    }

    @Published var authGraceSeconds: Int {
        didSet {
            let clamped = max(0, min(authGraceSeconds, 300))
            if clamped != authGraceSeconds {
                authGraceSeconds = clamped
                return
            }
            defaults.set(authGraceSeconds, forKey: Keys.authGraceSeconds)
        }
    }

    var isAppLocked: Bool { lockState.isLocked }
    var isAuthenticating: Bool { authenticationState.isAuthenticating }

    var isBiometryAvailable: Bool {
        if case .available = biometricAvailability {
            return true
        }
        return false
    }

    var biometryKind: BiometryKind {
        if case .available(let kind) = biometricAvailability {
            return kind
        }
        return .none
    }

    private let defaults: UserDefaults
    private let authService: any BiometricAuthServing
    private var unlockedServers: [UUID: Date] = [:]

    init(defaults: UserDefaults, authService: any BiometricAuthServing) {
        self.defaults = defaults
        self.authService = authService
        self.biometricAvailability = authService.availability()

        let fullLockEnabled = defaults.object(forKey: Keys.fullAppLockEnabled) as? Bool ?? false
        self.fullAppLockEnabled = fullLockEnabled
        self.lockOnBackground = defaults.object(forKey: Keys.lockOnBackground) as? Bool ?? true
        let storedGrace = defaults.object(forKey: Keys.authGraceSeconds) as? Int ?? 30
        self.authGraceSeconds = max(0, min(storedGrace, 300))
        self.lockState = fullLockEnabled
            ? .locked(generation: UUID())
            : .unlocked(at: nil)
    }

    func refreshBiometryAvailability() {
        let nextAvailability = authService.availability()
        if biometricAvailability != nextAvailability {
            biometricAvailability = nextAvailability
        }
    }

    func requestSetFullAppLockEnabled(_ enabled: Bool) async {
        lastFailure = nil

        guard enabled != fullAppLockEnabled else { return }

        if !enabled {
            guard await authenticate(
                reason: .disableAppLock,
                purpose: .disableFullAppLock
            ) else { return }
            fullAppLockEnabled = false
            return
        }

        refreshBiometryAvailability()
        guard case .available(let biometry) = biometricAvailability else {
            if case .unavailable(let reason) = biometricAvailability {
                lastFailure = .biometryUnavailable(reason)
            }
            return
        }

        guard await authenticate(
            reason: .enableAppLock(biometry: biometry),
            purpose: .enableFullAppLock
        ) else { return }

        fullAppLockEnabled = true
        lockState = .unlocked(at: Date())
    }

    func ensureAppUnlocked() async -> Bool {
        guard fullAppLockEnabled else { return true }
        guard case .locked(let lockGeneration) = lockState else { return true }

        guard await authenticate(
            reason: .unlockApp(biometry: biometryKind),
            purpose: .unlockApp(lockGeneration: lockGeneration)
        ) else { return false }
        guard lockState == .locked(generation: lockGeneration) else { return false }

        lockState = .unlocked(at: Date())
        lastFailure = nil
        return true
    }

    func authorizeProtectedServerAction(
        _ server: Server,
        action: AppLockAuthenticationState.ProtectedServerAction
    ) async -> Bool {
        guard server.requiresBiometricUnlock else { return true }

        guard await authenticate(
            reason: .protectedServerAction(action: action, serverName: server.name),
            purpose: .protectedServerAction(serverID: server.id, action: action)
        ) else { return false }

        lastFailure = nil
        return true
    }

    func canAccessServerWithoutPrompt(_ server: Server) -> Bool {
        guard server.requiresBiometricUnlock else { return true }
        purgeExpiredUnlocks()

        if hasValidGrant(lockState.lastUnlockAt) {
            return true
        }

        return hasValidGrant(unlockedServers[server.id])
    }

    func ensureServerUnlocked(_ server: Server) async -> Bool {
        guard server.requiresBiometricUnlock else { return true }

        if fullAppLockEnabled, isAppLocked {
            guard await ensureAppUnlocked() else { return false }
        }

        if canAccessServerWithoutPrompt(server) {
            return true
        }

        guard await authenticate(
            reason: .unlockServer(name: server.name),
            purpose: .unlockServer(serverID: server.id)
        ) else { return false }

        unlockedServers[server.id] = Date()
        lastFailure = nil
        return true
    }

    func handleSceneActivation() {
        refreshBiometryAvailability()
    }

    func lockIfNeededForBackground() {
        guard fullAppLockEnabled, lockOnBackground else { return }
        lockAppNow()
    }

    func lockAppNow() {
        guard fullAppLockEnabled else { return }
        lockState = .locked(generation: UUID())
        invalidateAuthentication()
        unlockedServers.removeAll()
    }

    private func hasValidGrant(_ date: Date?) -> Bool {
        guard let date else { return false }
        guard authGraceSeconds > 0 else { return false }
        return Date().timeIntervalSince(date) <= TimeInterval(authGraceSeconds)
    }

    private func purgeExpiredUnlocks() {
        guard authGraceSeconds > 0 else {
            unlockedServers.removeAll()
            return
        }

        let threshold = Date().addingTimeInterval(-TimeInterval(authGraceSeconds))
        unlockedServers = unlockedServers.filter { $0.value >= threshold }
    }

    private func authenticate(
        reason: BiometricAuthenticationReason,
        purpose: AppLockAuthenticationState.Purpose
    ) async -> Bool {
        guard authenticationState == .idle else { return false }

        let attemptID = UUID()
        authenticationState = .authenticating(attemptID: attemptID, purpose: purpose)
        defer {
            if authenticationState.accepts(attemptID: attemptID, purpose: purpose) {
                authenticationState = .idle
            }
        }

        do {
            try await authService.authenticate(reason: reason, allowPasscodeFallback: true)
            return authenticationState.accepts(attemptID: attemptID, purpose: purpose)
        } catch let failure as BiometricAuthenticationFailure {
            guard authenticationState.accepts(attemptID: attemptID, purpose: purpose) else {
                return false
            }
            if !failure.isCancellation {
                lastFailure = .authentication(failure)
            }
            return false
        } catch is CancellationError {
            return false
        } catch {
            guard authenticationState.accepts(attemptID: attemptID, purpose: purpose) else {
                return false
            }
            lastFailure = .authentication(.system(message: error.localizedDescription))
            return false
        }
    }

    private func invalidateAuthentication() {
        authenticationState = .idle
    }
}
