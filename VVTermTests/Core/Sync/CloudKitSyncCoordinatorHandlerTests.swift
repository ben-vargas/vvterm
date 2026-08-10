import Foundation
import Testing
@testable import VVTerm

private enum PendingMutationHandlerTestError: Error {
    case failed
}

@MainActor
private final class PendingMutationHandlerStub: PendingCloudKitMutationHandling {
    enum Behavior {
        case succeed
        case fail
        case cancel
    }

    var behaviors: [Behavior]
    private(set) var received: [PendingCloudKitMutation] = []

    init(behaviors: [Behavior]) {
        self.behaviors = behaviors
    }

    func handle(_ mutation: PendingCloudKitMutation) async throws {
        received.append(mutation)
        guard !behaviors.isEmpty else { return }
        switch behaviors.removeFirst() {
        case .succeed:
            return
        case .fail:
            throw PendingMutationHandlerTestError.failed
        case .cancel:
            throw CancellationError()
        }
    }
}

@MainActor
struct CloudKitSyncCoordinatorHandlerTests {
    @Test
    func handlerFailurePersistsRetryAndLaterSuccessRemovesMutation() async throws {
        let suiteName = "CloudKitSyncCoordinatorHandlerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var currentDate = Date(timeIntervalSinceReferenceDate: 20_000)
        let handler = PendingMutationHandlerStub(behaviors: [.fail, .succeed])
        let coordinator = CloudKitSyncCoordinator(
            mutationHandler: handler,
            queue: PendingCloudKitSyncQueue(
                storageKey: "handlerRetryQueue",
                defaults: defaults
            ),
            isSyncEnabled: { true },
            now: { currentDate },
            makeID: UUID.init
        )
        let theme = TerminalTheme(
            name: "Retry Theme",
            content: "background = #000000\nforeground = #FFFFFF\n",
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let payload = try PendingCloudKitMutationPayload.terminalThemeUpsert(theme)

        try coordinator.enqueue(
            PendingCloudKitMutation(payload: payload)
        )
        await coordinator.drainPendingMutations()

        let failedMutation = try #require(coordinator.snapshot().first)
        let firstReceivedPayload = try #require(handler.received.first?.payload)
        let decodedTheme = try firstReceivedPayload.decode(
            TerminalTheme.self,
            entityType: TerminalThemePendingCloudKitPayloadCodec.themeEntityType,
            operation: .upsert
        )
        let receivedTheme = try #require(decodedTheme)
        #expect(handler.received.map(\.payload) == [payload])
        #expect(receivedTheme == theme)
        #expect(failedMutation.retryCount == 1)
        #expect(failedMutation.nextRetryAt == currentDate.addingTimeInterval(30))

        currentDate = try #require(failedMutation.nextRetryAt)
        await coordinator.drainPendingMutations()

        let expectedReceivedPayloads = [payload, payload]
        #expect(handler.received.map(\.payload) == expectedReceivedPayloads)
        #expect(coordinator.snapshot().isEmpty)
    }

    @Test
    func cancellationLeavesMutationUnchangedAndImmediatelyRetryable() async throws {
        let suiteName = "CloudKitSyncCoordinatorHandlerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let handler = PendingMutationHandlerStub(behaviors: [.cancel, .succeed])
        let coordinator = CloudKitSyncCoordinator(
            mutationHandler: handler,
            queue: PendingCloudKitSyncQueue(
                storageKey: "handlerCancellationQueue",
                defaults: defaults
            ),
            isSyncEnabled: { true },
            now: { Date(timeIntervalSinceReferenceDate: 30_000) },
            makeID: UUID.init
        )
        let theme = TerminalTheme(
            name: "Cancelled Theme",
            content: "background = #000000\nforeground = #FFFFFF\n",
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let payload = try PendingCloudKitMutationPayload.terminalThemeUpsert(theme)
        let mutation = PendingCloudKitMutation(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            payload: payload,
            createdAt: Date(timeIntervalSinceReferenceDate: 200)
        )

        try coordinator.enqueue(mutation)
        await coordinator.drainPendingMutations()

        #expect(coordinator.snapshot() == [mutation])
        #expect(handler.received == [mutation])

        await coordinator.drainPendingMutations()

        #expect(handler.received == [mutation, mutation])
        #expect(coordinator.snapshot().isEmpty)
    }

    @Test
    func removalPersistenceFailureKeepsSuccessfulMutationDurable() async throws {
        let suiteName = "CloudKitSyncCoordinatorHandlerTests.remove.\(UUID().uuidString)"
        let defaults = WriteRejectingUserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "handlerRemovalFailureQueue"
        let handler = PendingMutationHandlerStub(behaviors: [.succeed])
        let coordinator = CloudKitSyncCoordinator(
            mutationHandler: handler,
            queue: PendingCloudKitSyncQueue(
                storageKey: storageKey,
                defaults: defaults
            ),
            isSyncEnabled: { true },
            now: { Date(timeIntervalSinceReferenceDate: 40_000) },
            makeID: UUID.init
        )
        let mutation = try makeMutation(idSuffix: 2)
        try coordinator.enqueue(mutation)

        defaults.rejectWrites = true
        await coordinator.drainPendingMutations()

        #expect(handler.received == [mutation])
        #expect(coordinator.snapshot() == [mutation])
        defaults.rejectWrites = false
        let reloadedQueue = PendingCloudKitSyncQueue(
            storageKey: storageKey,
            defaults: defaults
        )
        #expect(reloadedQueue.snapshot() == [mutation])
    }

    @Test
    func retryPersistenceFailureKeepsOriginalMutationDurable() async throws {
        let suiteName = "CloudKitSyncCoordinatorHandlerTests.retry.\(UUID().uuidString)"
        let defaults = WriteRejectingUserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "handlerRetryPersistenceFailureQueue"
        let handler = PendingMutationHandlerStub(behaviors: [.fail])
        let coordinator = CloudKitSyncCoordinator(
            mutationHandler: handler,
            queue: PendingCloudKitSyncQueue(
                storageKey: storageKey,
                defaults: defaults
            ),
            isSyncEnabled: { true },
            now: { Date(timeIntervalSinceReferenceDate: 50_000) },
            makeID: UUID.init
        )
        let mutation = try makeMutation(idSuffix: 3)
        try coordinator.enqueue(mutation)

        defaults.rejectWrites = true
        await coordinator.drainPendingMutations()

        #expect(handler.received == [mutation])
        #expect(coordinator.snapshot() == [mutation])
        defaults.rejectWrites = false
        let reloadedQueue = PendingCloudKitSyncQueue(
            storageKey: storageKey,
            defaults: defaults
        )
        #expect(reloadedQueue.snapshot() == [mutation])
    }

    private func makeMutation(idSuffix: Int) throws -> PendingCloudKitMutation {
        let theme = TerminalTheme(
            name: "Durable Theme",
            content: "background = #000000\nforeground = #FFFFFF\n",
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        return PendingCloudKitMutation(
            id: UUID(
                uuidString: String(
                    format: "10000000-0000-0000-0000-%012d",
                    idSuffix
                )
            )!,
            payload: try PendingCloudKitMutationPayload.terminalThemeUpsert(theme),
            createdAt: Date(timeIntervalSinceReferenceDate: 200)
        )
    }
}
