import Combine
import Foundation
import Testing
@testable import VVTerm

private actor ReconnectCancellationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var cancellationObserved = false

    func waitIgnoringCancellation() async {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        cancellationObserved = Task.isCancelled
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class ReconnectOwnerFixture {
    var facts: [UUID: TerminalReconnectPaneFacts] = [:]
    var cleanupCount = 0
    var startCount = 0
    var failureCount = 0
    var events: [TerminalReconnectCoordinator.EventStage] = []
    var firstCleanupGate: ReconnectCancellationGate?
    #if os(macOS)
    var recoveryGate: ReconnectCancellationGate?
    var recoveryCandidates: [MacTerminalRecoveryCandidate] = []
    #endif

    func access() -> TerminalReconnectAccess {
        #if os(macOS)
        TerminalReconnectAccess(
            paneFacts: { [weak self] in self?.facts[$0] },
            paneIDs: { [weak self] in self.map { Array($0.facts.keys) } ?? [] },
            paneIDsForServer: { _ in [] },
            prepareTransport: { [weak self] _ in
                guard let self else { return }
                cleanupCount += 1
                if cleanupCount == 1, let firstCleanupGate {
                    await firstCleanupGate.waitIgnoringCancellation()
                }
            },
            startConnection: { [weak self] _ in
                guard let self else { return false }
                startCount += 1
                return true
            },
            failConnection: { [weak self] _ in self?.failureCount += 1 },
            offlineMacRecoveryPaneIDs: { [] },
            macRecoveryCandidates: { [weak self] in self?.recoveryCandidates ?? [] },
            beginEternalTerminalProbe: { _ in nil },
            hasVerifiedLiveTransport: { [weak self] _, _ in
                guard let recoveryGate = self?.recoveryGate else { return false }
                await recoveryGate.waitIgnoringCancellation()
                return false
            },
            markMoshConnected: { _ in }
        )
        #else
        TerminalReconnectAccess(
            paneFacts: { [weak self] in self?.facts[$0] },
            paneIDs: { [weak self] in self.map { Array($0.facts.keys) } ?? [] },
            paneIDsForServer: { _ in [] },
            prepareTransport: { [weak self] _ in
                guard let self else { return }
                cleanupCount += 1
                if cleanupCount == 1, let firstCleanupGate {
                    await firstCleanupGate.waitIgnoringCancellation()
                }
            },
            startConnection: { [weak self] _ in
                guard let self else { return false }
                startCount += 1
                return true
            },
            failConnection: { [weak self] _ in self?.failureCount += 1 }
        )
        #endif
    }
}

@MainActor
struct TerminalReconnectCoordinatorTests {
    private func makeCoordinator(
        fixture: ReconnectOwnerFixture,
        network: TerminalNetworkReadiness = .ready,
        applicationIsActive: Bool = true,
        appIsLocked: Bool = false,
        retryDelay: Duration = .seconds(5),
        sleep: @escaping TerminalReconnectCoordinator.Sleep = {
            try await Task.sleep(for: $0)
        }
    ) -> TerminalReconnectCoordinator {
        TerminalReconnectCoordinator(
            access: fixture.access(),
            initialNetworkReadiness: network,
            initialApplicationIsActive: applicationIsActive,
            initialAppIsLocked: appIsLocked,
            retryDelay: retryDelay,
            sleep: sleep,
            onEvent: { [weak fixture] in fixture?.events.append($0.stage) },
            onChange: {}
        )
    }

    private func eventually(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func eventuallyAsync(
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    @Test
    func twoOwnersDoNotShareAttemptsOrConnectionGenerations() async {
        let paneId = UUID()
        let firstFixture = ReconnectOwnerFixture()
        let secondFixture = ReconnectOwnerFixture()
        firstFixture.facts[paneId] = .init(connectionState: .disconnected, hasEstablishedConnection: true)
        secondFixture.facts[paneId] = .init(connectionState: .disconnected, hasEstablishedConnection: true)
        let first = makeCoordinator(fixture: firstFixture)
        let second = makeCoordinator(fixture: secondFixture)

        #expect(first.request(for: paneId, requiresReadyNetwork: true))
        #expect(await eventually { firstFixture.startCount == 1 })
        #expect(second.attempt(for: paneId) == nil)
        #expect(second.connectionGeneration(for: paneId) == paneId)
        #expect(first.connectionGeneration(for: paneId) != paneId)

        #expect(second.request(for: paneId, requiresReadyNetwork: true))
        #expect(await eventually { secondFixture.startCount == 1 })
        #expect(first.connectionGeneration(for: paneId) != second.connectionGeneration(for: paneId))
    }

    @Test
    func staleGenerationCannotPublishAfterReplacementCleanup() async {
        let paneId = UUID()
        let blocker = ReconnectCancellationGate()
        let fixture = ReconnectOwnerFixture()
        fixture.firstCleanupGate = blocker
        fixture.facts[paneId] = .init(connectionState: .disconnected, hasEstablishedConnection: true)
        let coordinator = makeCoordinator(fixture: fixture)
        let staleGeneration = UUID()
        let replacementGeneration = UUID()

        #expect(coordinator.request(
            for: paneId,
            requiresReadyNetwork: true,
            generation: staleGeneration,
            replacingCurrent: true
        ))
        #expect(await eventuallyAsync { await blocker.started })
        #expect(coordinator.request(
            for: paneId,
            requiresReadyNetwork: true,
            generation: replacementGeneration,
            replacingCurrent: true
        ))
        #expect(await eventually { fixture.startCount == 1 })
        #expect(coordinator.attempt(for: paneId)?.generation == replacementGeneration)

        await blocker.release()
        await Task.yield()
        #expect(fixture.startCount == 1)
        #expect(coordinator.attempt(for: paneId)?.generation == replacementGeneration)
    }

    @Test
    func networkApplicationAndLockSignalsResumeInOrderWithoutDuplicateStart() async {
        let paneId = UUID()
        let fixture = ReconnectOwnerFixture()
        fixture.facts[paneId] = .init(connectionState: .disconnected, hasEstablishedConnection: true)
        let coordinator = makeCoordinator(
            fixture: fixture,
            applicationIsActive: false,
            appIsLocked: true
        )

        #expect(coordinator.request(for: paneId, requiresReadyNetwork: true))
        #expect(await eventually {
            coordinator.attempt(for: paneId)?.phase == .waitingForApplication
        })
        coordinator.receiveApplicationActivity(true)
        #expect(coordinator.attempt(for: paneId)?.phase == .waitingForUnlock)

        coordinator.receiveNetworkReadiness(.unavailable)
        coordinator.receiveAppLock(false)
        #expect(await eventually {
            coordinator.attempt(for: paneId)?.phase == .waitingForNetwork
        })
        #expect(fixture.startCount == 0)

        coordinator.receiveNetworkReadiness(.ready)
        coordinator.receiveNetworkReadiness(.ready)
        coordinator.receiveApplicationActivity(true)
        coordinator.receiveAppLock(false)
        #expect(await eventually { fixture.startCount == 1 })
        #expect(coordinator.attempt(for: paneId)?.phase == .connecting)
    }

    @Test
    func duplicateGenerationDoesNotCreateSecondReconnect() async {
        let paneId = UUID()
        let generation = UUID()
        let fixture = ReconnectOwnerFixture()
        fixture.facts[paneId] = .init(connectionState: .disconnected, hasEstablishedConnection: true)
        let coordinator = makeCoordinator(fixture: fixture)

        #expect(coordinator.request(
            for: paneId,
            requiresReadyNetwork: true,
            generation: generation,
            replacingCurrent: true
        ))
        #expect(!coordinator.request(
            for: paneId,
            requiresReadyNetwork: true,
            generation: generation,
            replacingCurrent: true
        ))
        #expect(await eventually { fixture.startCount == 1 })
        #expect(fixture.cleanupCount == 1)
    }

    @Test
    func blockedCleanupDoesNotRetainOwnerAndObservesCancellation() async {
        let paneId = UUID()
        let blocker = ReconnectCancellationGate()
        let fixture = ReconnectOwnerFixture()
        fixture.firstCleanupGate = blocker
        fixture.facts[paneId] = .init(connectionState: .disconnected, hasEstablishedConnection: true)
        var coordinator: TerminalReconnectCoordinator? = makeCoordinator(fixture: fixture)
        weak var weakCoordinator = coordinator

        #expect(coordinator?.request(for: paneId, requiresReadyNetwork: true) == true)
        #expect(await eventuallyAsync { await blocker.started })
        coordinator = nil
        #expect(weakCoordinator == nil)

        await blocker.release()
        #expect(await eventuallyAsync { await blocker.cancellationObserved })
        #expect(fixture.startCount == 0)
    }

    @Test
    func blockedRetrySleepDoesNotRetainOwnerAndObservesCancellation() async {
        let paneId = UUID()
        let retryGate = ReconnectCancellationGate()
        let fixture = ReconnectOwnerFixture()
        fixture.facts[paneId] = .init(connectionState: .connected, hasEstablishedConnection: true)
        var coordinator: TerminalReconnectCoordinator? = makeCoordinator(
            fixture: fixture,
            retryDelay: .seconds(5),
            sleep: { _ in await retryGate.waitIgnoringCancellation() }
        )
        weak var weakCoordinator = coordinator
        coordinator?.reconcileAutomaticReconnect(
            for: paneId,
            sceneIsActive: true,
            applicationIsActive: true,
            automaticReconnectAllowed: true
        )
        fixture.facts[paneId] = .init(
            connectionState: .failed("temporary"),
            hasEstablishedConnection: true
        )
        coordinator?.connectionStateDidChange(for: paneId)

        #expect(await eventuallyAsync { await retryGate.started })
        coordinator = nil
        #expect(weakCoordinator == nil)
        await retryGate.release()
        #expect(await eventuallyAsync { await retryGate.cancellationObserved })
        #expect(fixture.startCount == 0)
    }

    #if os(macOS)
    @Test
    func blockedPlatformRecoveryDoesNotRetainOwnerOrPublishLateReconnect() async {
        let paneId = UUID()
        let recoveryGate = ReconnectCancellationGate()
        let fixture = ReconnectOwnerFixture()
        fixture.recoveryGate = recoveryGate
        fixture.facts[paneId] = .init(connectionState: .connected, hasEstablishedConnection: true)
        fixture.recoveryCandidates = [MacTerminalRecoveryCandidate(
            paneId: paneId,
            strategy: .verifyOrReplace
        )]
        var coordinator: TerminalReconnectCoordinator? = makeCoordinator(fixture: fixture)
        weak var weakCoordinator = coordinator

        coordinator?.receiveMacRecoverySignal(.sleep)
        coordinator?.receiveMacRecoverySignal(.wake)
        #expect(await eventuallyAsync { await recoveryGate.started })
        coordinator = nil
        #expect(weakCoordinator == nil)

        await recoveryGate.release()
        #expect(await eventuallyAsync { await recoveryGate.cancellationObserved })
        #expect(fixture.startCount == 0)
    }
    #endif
}
