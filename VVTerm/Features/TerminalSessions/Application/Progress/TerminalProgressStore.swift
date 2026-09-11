import Combine
import Foundation

/// Owns progress and expiry for current terminal panes. No progress is persisted.
@MainActor
final class TerminalProgressStore: ObservableObject {
    @Published private(set) var states: [UUID: TerminalProgress] = [:]
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    private let sleep: @Sendable () async throws -> Void

    init(sleep: @escaping @Sendable () async throws -> Void = {
        try await Task.sleep(for: .seconds(15))
    }) {
        self.sleep = sleep
    }

    deinit {
        for task in expiryTasks.values { task.cancel() }
    }

    func apply(_ progress: TerminalProgress, for paneId: UUID) {
        expiryTasks.removeValue(forKey: paneId)?.cancel()
        guard progress != .inactive else {
            if states[paneId] != nil { states.removeValue(forKey: paneId) }
            return
        }
        if states[paneId] != progress { states[paneId] = progress }
        expiryTasks[paneId] = Task { [weak self, sleep] in
            do {
                try await sleep()
                try Task.checkCancellation()
                self?.clear(paneId)
            } catch {
                // Cancellation means a later report or pane removal owns the state.
            }
        }
    }

    func clear(_ paneId: UUID) {
        apply(.inactive, for: paneId)
    }

    func reset() {
        for task in expiryTasks.values { task.cancel() }
        expiryTasks.removeAll()
        states.removeAll()
    }
}
