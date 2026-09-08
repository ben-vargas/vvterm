import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class CloudRefreshGate {
    var calls = 0
    var continuation: CheckedContinuation<Void, Never>?

    func run() async {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { continuation = $0 }
        }
    }

    func waitUntilBlocked() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while continuation == nil, ContinuousClock.now < deadline { await Task.yield() }
        try #require(continuation != nil)
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
struct AppCloudDataSyncCoordinatorTests {
    @Test
    func refreshRunsEveryConfiguredDataOwnerInOrder() async throws {
        var events: [Int] = []
        let sync = AppCloudDataSyncCoordinator(isEnabled: { true }, steps: [
            { events.append(1) }, { events.append(2) }, { events.append(3) }
        ])
        try await sync.refresh()
        #expect(events == [1, 2, 3])
    }

    @Test
    func signalsDuringFetchScheduleOneFollowUpPass() async throws {
        let gate = CloudRefreshGate()
        let sync = AppCloudDataSyncCoordinator(isEnabled: { true }, steps: [{ await gate.run() }])
        let first = Task { try await sync.refresh() }
        try await gate.waitUntilBlocked()
        var started = 0
        let second = Task { started += 1; try await sync.refresh() }
        let third = Task { started += 1; try await sync.refresh() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while started < 2, ContinuousClock.now < deadline { await Task.yield() }
        try #require(started == 2)
        gate.release()
        try await first.value
        try await second.value
        try await third.value
        #expect(gate.calls == 2)
    }

    @Test
    func failedOwnerDoesNotBlockOtherOwnersAndFailureIsReported() async {
        var refreshedOtherOwner = false
        let sync = AppCloudDataSyncCoordinator(isEnabled: { true }, steps: [
            { throw AppCloudDataSyncError.serverData },
            { refreshedOtherOwner = true }
        ])
        await #expect(throws: AppCloudDataSyncError.serverData) { try await sync.refresh() }
        #expect(refreshedOtherOwner)
    }

    @Test
    func disabledSyncDoesNotReadCloudData() async {
        var calls = 0
        let sync = AppCloudDataSyncCoordinator(isEnabled: { false }, steps: [{ calls += 1 }])
        await #expect(throws: CancellationError.self) { try await sync.refresh() }
        #expect(calls == 0)
    }

    @Test
    func cancellationStopsRemainingOwnersAndAllowsRetry() async throws {
        let gate = CloudRefreshGate()
        var laterCalls = 0
        let sync = AppCloudDataSyncCoordinator(isEnabled: { true }, steps: [
            { await gate.run() }, { laterCalls += 1 }
        ])
        let first = Task { try await sync.refresh() }
        try await gate.waitUntilBlocked()
        sync.cancel()
        let retry = Task { try await sync.refresh() }
        await Task.yield()
        #expect(gate.calls == 1)
        gate.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await retry.value
        #expect(gate.calls == 2)
        #expect(laterCalls == 1)
    }
}
