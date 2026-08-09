import Foundation
import Testing
@testable import VVTerm

@MainActor
struct LocalSSHDiscoveryStateTests {
    @Test
    func activeSourcesArePartOfTheScanningState() {
        var state = LocalSSHDiscoveryState()
        let scanID = UUID()

        state.start(id: scanID)
        state.handle(.sourceStatus(.bonjourStarted), scanID: scanID)
        state.handle(.sourceStatus(.probeStarted), scanID: scanID)

        #expect(state.isScanning)
        #expect(state.isSourceActive(.bonjour))
        #expect(state.isSourceActive(.probe))

        state.handle(.sourceStatus(.bonjourFinished), scanID: scanID)

        #expect(!state.isSourceActive(.bonjour))
        #expect(state.isSourceActive(.probe))
    }

    @Test
    func staleCompletionCannotFinishANewerScan() {
        var state = LocalSSHDiscoveryState()
        let oldScanID = UUID()
        let newScanID = UUID()

        state.start(id: oldScanID)
        state.start(id: newScanID)

        let acceptedStaleCompletion = state.handle(.scanningFinished, scanID: oldScanID)

        #expect(!acceptedStaleCompletion)
        #expect(state.isScanning)

        let acceptedCurrentCompletion = state.handle(.scanningFinished, scanID: newScanID)

        #expect(acceptedCurrentCompletion)
        #expect(!state.isScanning)
        #expect(state.phase == .completed(.unknown))
    }

    @Test
    func failureRemainsVisibleAfterTheServiceFinishes() {
        var state = LocalSSHDiscoveryState()
        let scanID = UUID()

        state.start(id: scanID)
        state.handle(.permissionDenied, scanID: scanID)
        state.handle(.failed("Local network access failed"), scanID: scanID)
        state.handle(.scanningFinished, scanID: scanID)

        #expect(!state.isScanning)
        #expect(state.permission == .denied)
        #expect(state.error == "Local network access failed")
    }

    @Test
    func stoppingAScanClearsItsActiveSources() {
        var state = LocalSSHDiscoveryState()
        let scanID = UUID()

        state.start(id: scanID)
        state.handle(.sourceStatus(.bonjourStarted), scanID: scanID)
        state.stop(clearResults: false)

        #expect(!state.isScanning)
        #expect(!state.isSourceActive(.bonjour))
        #expect(state.phase == .completed(.unknown))
    }
}
