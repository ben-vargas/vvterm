import Foundation
import os.log

/// Serializes cloud reads for manual sync, push notifications, and app activation.
@MainActor
final class AppCloudDataSyncCoordinator {
    private enum State {
        case idle
        case running(Task<Void, Error>, followUp: Bool)
    }

    private let isEnabled: @MainActor () -> Bool
    private let steps: [@MainActor () async throws -> Void]
    private var state = State.idle

    init(
        isEnabled: @escaping @MainActor () -> Bool,
        steps: [@MainActor () async throws -> Void]
    ) {
        self.isEnabled = isEnabled
        self.steps = steps
    }

    deinit {
        if case .running(let task, _) = state { task.cancel() }
    }

    func refresh() async throws {
        try Task.checkCancellation()
        guard isEnabled() else { throw CancellationError() }
        if case .running(let task, _) = state {
            if task.isCancelled {
                // Finish cancellation before allowing a replacement to touch the same stores.
                _ = await task.result
                try await refresh()
                return
            }
            state = .running(task, followUp: true)
            try await task.value
            try Task.checkCancellation()
            return
        }

        let task = Task { @MainActor [weak self, steps, isEnabled] in
            defer { self?.state = .idle }
            var result: Result<Void, Error>
            repeat {
                self?.beginPass()
                do {
                    try await Self.refreshAll(steps, isEnabled: isEnabled)
                    result = .success(())
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    result = .failure(error)
                }
            } while self?.needsFollowUp == true
            try result.get()
        }
        state = .running(task, followUp: false)
        try await task.value
        try Task.checkCancellation()
    }

    func cancel() {
        if case .running(let task, _) = state { task.cancel() }
    }

    private func beginPass() {
        if case .running(let task, _) = state {
            state = .running(task, followUp: false)
        }
    }

    private var needsFollowUp: Bool {
        if case .running(_, let followUp) = state { return followUp }
        return false
    }

    private static func refreshAll(
        _ steps: [@MainActor () async throws -> Void],
        isEnabled: @MainActor () -> Bool
    ) async throws {
        var firstError: Error?
        let logger = Logger(subsystem: "app.vivy.VivyTerm", category: "CloudDataSync")
        for step in steps {
            try Task.checkCancellation()
            guard isEnabled() else { throw CancellationError() }
            do {
                try await step()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.error("Cloud data refresh failed: \(error.localizedDescription)")
                if firstError == nil { firstError = error }
            }
        }
        try Task.checkCancellation()
        guard isEnabled() else { throw CancellationError() }
        if let firstError { throw firstError }
    }
}

nonisolated enum AppCloudDataSyncError: Error, Equatable {
    case serverData
}
