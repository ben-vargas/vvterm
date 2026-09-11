import Foundation
import Testing
@testable import VVTerm

private actor ProgressSleepGate {
    var waits: [CheckedContinuation<Void, Never>] = []
    func sleep() async {
        await withCheckedContinuation { waits.append($0) }
    }
    func releaseFirst() { waits.removeFirst().resume() }
    var count: Int { waits.count }
}

@MainActor
struct TerminalProgressStoreTests {
    @Test
    func bridgeClampsValuesAndPreservesEveryState() {
        #expect(GhosttyProgressState.set.progress(value: Int.max) == .determinate(100))
        #expect(GhosttyProgressState.set.progress(value: Int.min) == .determinate(0))
        #expect(GhosttyProgressState.set.progress(value: nil) == .indeterminate)
        #expect(GhosttyProgressState.error.progress(value: 50) == .error(50))
        #expect(GhosttyProgressState.pause.progress(value: nil) == .paused(nil))
        #expect(GhosttyProgressState.indeterminate.progress(value: 50) == .indeterminate)
        #expect(GhosttyProgressState.remove.progress(value: 50) == .inactive)
        #expect(GhosttyProgressState.unknown.progress(value: 50) == nil)
        #expect(TerminalProgress.paused(nil).barPercent == 100)
        #expect(TerminalProgress.paused(nil).percent == nil)
    }

    @Test
    func paneIsolationRemovalAndReset() {
        let store = TerminalProgressStore()
        let first = UUID(), second = UUID()
        store.apply(.determinate(50), for: first)
        store.apply(.error(20), for: second)
        store.clear(first)
        #expect(store.states[first] == nil)
        #expect(store.states[second] == .error(20))
        store.reset()
        #expect(store.states.isEmpty)
    }

    @Test
    func cancelledExpiryCannotClearLaterReport() async throws {
        let gate = ProgressSleepGate()
        let store = TerminalProgressStore(sleep: { await gate.sleep() })
        let pane = UUID()
        store.apply(.determinate(50), for: pane)
        try await waitForCount(1, gate: gate)
        // An identical update must also renew the timeout.
        store.apply(.determinate(50), for: pane)
        try await waitForCount(2, gate: gate)
        await gate.releaseFirst()
        for _ in 0..<20 { await Task.yield() }
        #expect(store.states[pane] == .determinate(50))
        await gate.releaseFirst()
        let deadline = ContinuousClock.now + .seconds(2)
        while store.states[pane] != nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(store.states[pane] == nil)
    }

    private func waitForCount(_ count: Int, gate: ProgressSleepGate) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while await gate.count < count, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await gate.count == count)
    }
}
