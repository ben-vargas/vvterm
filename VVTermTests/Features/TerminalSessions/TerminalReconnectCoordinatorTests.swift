import Foundation
import Testing
@testable import VVTerm

@MainActor
private final class ReconnectTestCounter {
    var cleanup = 0
    var starts = 0
    var failures = 0
    var events: [TerminalReconnectCoordinator.EventStage] = []
}

@MainActor
struct TerminalReconnectCoordinatorTests {
    private func eventually(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    @Test
    func offlinePreparationCleansOnceAndStartsOnceWhenNetworkBecomesReady() async {
        let counter = ReconnectTestCounter()
        let generation = UUID()
        let paneId = UUID()
        let coordinator = TerminalReconnectCoordinator(
            onEvent: { counter.events.append($0.stage) },
            onChange: {}
        )

        let attempt = coordinator.request(
            paneId: paneId,
            generation: generation,
            networkIsReady: false,
            replacingCurrent: true,
            cleanup: { _ in counter.cleanup += 1 },
            start: { _ in counter.starts += 1 },
            fail: { _ in counter.failures += 1 }
        )
        #expect(attempt != nil)
        #expect(await eventually { counter.cleanup == 1 })

        #expect(coordinator.attempt(for: paneId)?.phase == .waitingForNetwork)
        #expect(counter.cleanup == 1)
        #expect(counter.starts == 0)

        coordinator.networkBecameReady(for: generation)
        coordinator.networkBecameReady(for: generation)

        #expect(coordinator.attempt(for: paneId)?.phase == .connecting)
        #expect(counter.cleanup == 1)
        #expect(counter.starts == 1)
        #expect(counter.failures == 0)
        coordinator.complete(for: paneId)
    }

    @Test
    func stalePreparationCannotStartAfterReplacement() async {
        let counter = ReconnectTestCounter()
        let blocker = DeadlineBlocker()
        let paneId = UUID()
        let coordinator = TerminalReconnectCoordinator(
            onEvent: { counter.events.append($0.stage) },
            onChange: {}
        )

        _ = coordinator.request(
            paneId: paneId,
            generation: UUID(),
            networkIsReady: true,
            replacingCurrent: true,
            cleanup: { _ in
                counter.cleanup += 1
                await blocker.wait()
            },
            start: { _ in counter.starts += 100 },
            fail: { _ in counter.failures += 100 }
        )
        #expect(await eventually { counter.cleanup == 1 })

        let replacementGeneration = UUID()
        _ = coordinator.request(
            paneId: paneId,
            generation: replacementGeneration,
            networkIsReady: true,
            replacingCurrent: true,
            cleanup: { _ in counter.cleanup += 1 },
            start: { _ in counter.starts += 1 },
            fail: { _ in counter.failures += 1 }
        )
        #expect(await eventually { counter.starts == 1 })

        #expect(coordinator.attempt(for: paneId)?.generation == replacementGeneration)
        #expect(coordinator.attempt(for: paneId)?.phase == .connecting)
        #expect(counter.starts == 1)
        #expect(counter.failures == 0)
        blocker.release()
        coordinator.complete(for: paneId)
        #expect(await eventually { counter.events.contains(.staleResultRejected) })
    }

    @Test
    func networkDropDuringBlockedPreparationWaitsBeforeStarting() async {
        let counter = ReconnectTestCounter()
        let blocker = DeadlineBlocker()
        let generation = UUID()
        let paneId = UUID()
        let coordinator = TerminalReconnectCoordinator(onChange: {})

        _ = coordinator.request(
            paneId: paneId,
            generation: generation,
            networkIsReady: true,
            replacingCurrent: true,
            cleanup: { _ in
                counter.cleanup += 1
                await blocker.wait()
            },
            start: { _ in counter.starts += 1 },
            fail: { _ in counter.failures += 1 }
        )
        #expect(await eventually { counter.cleanup == 1 })

        coordinator.networkBecameUnavailable(for: generation)
        blocker.release()

        #expect(await eventually {
            coordinator.attempt(for: paneId)?.phase == .waitingForNetwork
        })
        #expect(counter.starts == 0)

        coordinator.networkBecameReady(for: generation)
        #expect(coordinator.attempt(for: paneId)?.phase == .connecting)
        #expect(counter.starts == 1)
        coordinator.complete(for: paneId)
    }

    @Test
    func networkDropDuringConnectionCleansBeforeOneReplacement() async {
        let counter = ReconnectTestCounter()
        let generation = UUID()
        let paneId = UUID()
        let coordinator = TerminalReconnectCoordinator(onChange: {})

        _ = coordinator.request(
            paneId: paneId,
            generation: generation,
            networkIsReady: true,
            replacingCurrent: true,
            cleanup: { _ in counter.cleanup += 1 },
            start: { _ in counter.starts += 1 },
            fail: { _ in counter.failures += 1 }
        )
        #expect(await eventually { counter.starts == 1 })

        coordinator.networkBecameUnavailable(for: generation)
        #expect(await eventually {
            coordinator.attempt(for: paneId)?.phase == .waitingForNetwork
        })
        #expect(counter.cleanup == 2)
        #expect(counter.starts == 1)

        coordinator.networkBecameReady(for: generation)
        coordinator.networkBecameReady(for: generation)
        #expect(coordinator.attempt(for: paneId)?.phase == .connecting)
        #expect(counter.starts == 2)
        coordinator.complete(for: paneId)
    }

    @Test
    func blockedPreparationReachesWaitingStateAtHardDeadline() async {
        let counter = ReconnectTestCounter()
        let blocker = DeadlineBlocker()
        let paneId = UUID()
        let coordinator = TerminalReconnectCoordinator(
            preparationTimeout: .milliseconds(20),
            onEvent: { counter.events.append($0.stage) },
            onChange: {}
        )

        _ = coordinator.request(
            paneId: paneId,
            networkIsReady: false,
            replacingCurrent: true,
            cleanup: { _ in
                counter.cleanup += 1
                await blocker.wait()
            },
            start: { _ in counter.starts += 1 },
            fail: { _ in counter.failures += 1 }
        )

        #expect(await eventually {
            coordinator.attempt(for: paneId)?.phase == .waitingForNetwork
        })
        #expect(counter.cleanup == 1)
        #expect(counter.starts == 0)
        #expect(counter.events.contains(.preparationDeadline))

        blocker.release()
        coordinator.invalidate(for: paneId)
        await Task.yield()
    }

    @Test
    func connectionDeadlineFailsOnceAndDoesNotReschedule() async {
        let counter = ReconnectTestCounter()
        let paneId = UUID()
        let coordinator = TerminalReconnectCoordinator(
            preparationTimeout: .seconds(1),
            connectionTimeout: .milliseconds(20),
            onEvent: { counter.events.append($0.stage) },
            onChange: {}
        )

        _ = coordinator.request(
            paneId: paneId,
            networkIsReady: true,
            replacingCurrent: true,
            cleanup: { _ in counter.cleanup += 1 },
            start: { _ in counter.starts += 1 },
            fail: { _ in counter.failures += 1 }
        )

        #expect(await eventually { counter.failures == 1 })
        #expect(coordinator.attempt(for: paneId) == nil)
        #expect(counter.cleanup == 2)
        #expect(counter.starts == 1)
        #expect(counter.events.contains(.connectionDeadline))

        try? await Task.sleep(for: .milliseconds(50))
        #expect(counter.failures == 1)
        #expect(counter.starts == 1)
    }

    @Test
    func injectedClockCanAdvanceEightHoursBeforeRecovery() {
        let paneId = UUID()
        let wakeTime = Date(timeIntervalSince1970: 8 * 60 * 60)
        let coordinator = TerminalReconnectCoordinator(
            now: { wakeTime },
            onChange: {}
        )

        let attempt = coordinator.request(
            paneId: paneId,
            networkIsReady: false,
            replacingCurrent: true,
            cleanup: { _ in },
            start: { _ in },
            fail: { _ in }
        )

        #expect(attempt?.startedAt == wakeTime)
        coordinator.invalidate(for: paneId)
    }
}
