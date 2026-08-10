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
            now: { currentDate }
        )
        let theme = TerminalTheme(
            name: "Retry Theme",
            content: "background = #000000\nforeground = #FFFFFF\n",
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )

        coordinator.enqueue(
            PendingCloudKitMutation(payload: .terminalThemeUpsert(theme))
        )
        await coordinator.drainPendingMutations()

        let failedMutation = try #require(coordinator.snapshot().first)
        #expect(handler.received.map(\.payload) == [.terminalThemeUpsert(theme)])
        #expect(failedMutation.retryCount == 1)
        #expect(failedMutation.nextRetryAt == currentDate.addingTimeInterval(30))

        currentDate = try #require(failedMutation.nextRetryAt)
        await coordinator.drainPendingMutations()

        #expect(handler.received.map(\.payload) == [
            .terminalThemeUpsert(theme),
            .terminalThemeUpsert(theme)
        ])
        #expect(coordinator.snapshot().isEmpty)
    }
}
