import Combine
import Foundation
import XCTest
@testable import VVTerm

@MainActor
final class AppLockManagerTests: XCTestCase {
    private final class StubBiometricAuthService: BiometricAuthServing {
        var availabilityResult: BiometricAvailability
        var authenticateError: Error?
        private(set) var authenticateReasons: [String] = []

        init(availabilityResult: BiometricAvailability) {
            self.availabilityResult = availabilityResult
        }

        func availability() -> BiometricAvailability {
            availabilityResult
        }

        func authenticate(localizedReason: String, allowPasscodeFallback: Bool) async throws {
            authenticateReasons.append(localizedReason)
            if let authenticateError {
                throw authenticateError
            }
        }
    }

    private final class DelayedBiometricAuthService: BiometricAuthServing {
        let availabilityResult: BiometricAvailability
        private(set) var authenticateReasons: [String] = []

        private let startedStream: AsyncStream<Void>
        private let startedContinuation: AsyncStream<Void>.Continuation
        private var authenticationContinuation: CheckedContinuation<Void, Error>?

        init(availabilityResult: BiometricAvailability) {
            self.availabilityResult = availabilityResult
            let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            self.startedStream = started.stream
            self.startedContinuation = started.continuation
        }

        func availability() -> BiometricAvailability {
            availabilityResult
        }

        func authenticate(localizedReason: String, allowPasscodeFallback: Bool) async throws {
            authenticateReasons.append(localizedReason)
            startedContinuation.yield()
            try await withCheckedThrowingContinuation { continuation in
                authenticationContinuation = continuation
            }
        }

        func waitUntilAuthenticationStarts() async {
            for await _ in startedStream {
                return
            }
        }

        func succeed() {
            authenticationContinuation?.resume()
            authenticationContinuation = nil
        }
    }

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "VVTermTests.AppLockManager.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testEnableFullAppLockRequiresAvailableBiometry() async {
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .unavailable("Biometry unavailable")
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)

        await manager.requestSetFullAppLockEnabled(true)

        XCTAssertFalse(manager.fullAppLockEnabled)
        XCTAssertEqual(manager.lastErrorMessage, "Biometry unavailable")
        XCTAssertTrue(authService.authenticateReasons.isEmpty)
    }

    func testEnableFullAppLockAuthenticatesAndUnlocksApp() async {
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)

        await manager.requestSetFullAppLockEnabled(true)

        XCTAssertTrue(manager.fullAppLockEnabled)
        XCTAssertFalse(manager.isAppLocked)
        XCTAssertEqual(authService.authenticateReasons.count, 1)
    }

    func testNewBackgroundLockRejectsPendingAuthenticationSuccess() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "security.fullAppLockEnabled")
        let authService = DelayedBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)

        let unlockTask = Task { await manager.ensureAppUnlocked() }
        await authService.waitUntilAuthenticationStarts()
        XCTAssertTrue(manager.isAuthenticating)

        manager.lockAppNow()
        authService.succeed()

        let didUnlock = await unlockTask.value
        XCTAssertFalse(didUnlock)
        XCTAssertTrue(manager.isAppLocked)
        XCTAssertFalse(manager.isAuthenticating)
        XCTAssertEqual(manager.authenticationState, .idle)
    }

    func testGraceSecondsClampToUpperBound() {
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.touchID)
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)

        manager.authGraceSeconds = 900

        XCTAssertEqual(manager.authGraceSeconds, 300)
    }

    func testSceneActivationDoesNotPublishWhenBiometryAvailabilityIsUnchanged() {
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.faceID)
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)
        var publicationCount = 0
        let cancellable = manager.objectWillChange.sink {
            publicationCount += 1
        }

        manager.handleSceneActivation()

        XCTAssertEqual(publicationCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testBiometryValuesAreDerivedFromAvailability() {
        let defaults = makeDefaults()
        let authService = StubBiometricAuthService(
            availabilityResult: .available(.touchID)
        )
        let manager = AppLockManager(defaults: defaults, authService: authService)

        XCTAssertEqual(manager.biometricAvailability, .available(.touchID))
        XCTAssertTrue(manager.isBiometryAvailable)
        XCTAssertEqual(manager.biometryKind, .touchID)
        XCTAssertNil(manager.biometryAvailabilityMessage)

        authService.availabilityResult = .unavailable("Biometry unavailable")
        manager.refreshBiometryAvailability()

        XCTAssertEqual(manager.biometricAvailability, .unavailable("Biometry unavailable"))
        XCTAssertFalse(manager.isBiometryAvailable)
        XCTAssertEqual(manager.biometryKind, .none)
        XCTAssertEqual(manager.biometryAvailabilityMessage, "Biometry unavailable")
    }
}
