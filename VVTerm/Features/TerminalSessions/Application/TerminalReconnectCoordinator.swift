import Foundation

@MainActor
final class TerminalReconnectCoordinator {
    nonisolated enum Phase: Hashable, Sendable {
        case preparing
        case waitingForNetwork
        case connecting
    }

    nonisolated struct Attempt: Hashable, Sendable {
        let id: UUID
        let paneId: UUID
        let generation: UUID
        let startedAt: Date
        var phase: Phase
    }

    nonisolated enum EventStage: String, Equatable, Sendable {
        case preparationStarted
        case cleanupStarted
        case cleanupCompleted
        case preparationDeadline
        case waitingForNetwork
        case connecting
        case connectionDeadline
        case cleanupDeadline
        case completed
        case invalidated
        case staleResultRejected
    }

    nonisolated struct Event: Sendable {
        let attempt: Attempt
        let stage: EventStage
        let systemUptime: TimeInterval
    }

    typealias Cleanup = @MainActor @Sendable (Attempt) async -> Void
    typealias Start = @MainActor @Sendable (Attempt) -> Void
    typealias Fail = @MainActor @Sendable (Attempt) -> Void
    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias EventHandler = @MainActor @Sendable (Event) -> Void

    private struct Record {
        var attempt: Attempt
        var networkIsReady: Bool
        let cleanup: Cleanup
        let start: Start
        let fail: Fail
        var task: Task<Void, Never>?
    }

    private let preparationTimeout: Duration
    private let connectionTimeout: Duration
    private let now: @Sendable () -> Date
    private let sleep: Sleep
    private let onEvent: EventHandler
    private let onChange: @MainActor @Sendable () -> Void
    private var records: [UUID: Record] = [:]

    init(
        preparationTimeout: Duration = .seconds(5),
        connectionTimeout: Duration = .seconds(45),
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) },
        onEvent: @escaping EventHandler = { _ in },
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.preparationTimeout = preparationTimeout
        self.connectionTimeout = connectionTimeout
        self.now = now
        self.sleep = sleep
        self.onEvent = onEvent
        self.onChange = onChange
    }

    func attempt(for paneId: UUID) -> Attempt? {
        records[paneId]?.attempt
    }

    var activePaneIDs: Set<UUID> {
        Set(records.keys)
    }

    @discardableResult
    func request(
        paneId: UUID,
        generation: UUID = UUID(),
        networkIsReady: Bool,
        replacingCurrent: Bool,
        cleanup: @escaping Cleanup,
        start: @escaping Start,
        fail: @escaping Fail
    ) -> Attempt? {
        if let current = records[paneId] {
            if current.attempt.generation == generation || !replacingCurrent {
                return nil
            }
            current.task?.cancel()
            emit(.invalidated, for: current.attempt)
        }

        let attempt = Attempt(
            id: UUID(),
            paneId: paneId,
            generation: generation,
            startedAt: now(),
            phase: .preparing
        )
        records[paneId] = Record(
            attempt: attempt,
            networkIsReady: networkIsReady,
            cleanup: cleanup,
            start: start,
            fail: fail,
            task: nil
        )
        emit(.preparationStarted, for: attempt)
        onChange()

        records[paneId]?.task = Task { [weak self] in
            await self?.prepare(attempt)
        }
        return attempt
    }

    func networkBecameReady(for generation: UUID) {
        let paneIds = records.compactMap { paneId, record in
            record.attempt.generation == generation ? paneId : nil
        }
        for paneId in paneIds {
            guard var record = records[paneId] else { continue }
            record.networkIsReady = true
            records[paneId] = record
            if record.attempt.phase == .waitingForNetwork {
                beginConnection(record.attempt)
            }
        }
    }

    /// Prevents preparation that began on a ready path from publishing a new
    /// connection after that path becomes unavailable. Connecting attempts are
    /// replaced with a fresh cleanup attempt for the same recovery generation.
    func networkBecameUnavailable(for generation: UUID) {
        let activeRecords = records.values.filter {
            $0.attempt.generation == generation
        }

        for activeRecord in activeRecords {
            let paneId = activeRecord.attempt.paneId
            guard var current = currentRecord(for: activeRecord.attempt) else { continue }
            current.networkIsReady = false

            switch current.attempt.phase {
            case .preparing, .waitingForNetwork:
                records[paneId] = current

            case .connecting:
                records.removeValue(forKey: paneId)
                current.task?.cancel()
                emit(.invalidated, for: current.attempt)
                _ = request(
                    paneId: paneId,
                    generation: current.attempt.generation,
                    networkIsReady: false,
                    replacingCurrent: true,
                    cleanup: current.cleanup,
                    start: current.start,
                    fail: current.fail
                )
            }
        }
    }

    func complete(for paneId: UUID) {
        removeAttempt(for: paneId, event: .completed)
    }

    func invalidate(for paneId: UUID) {
        removeAttempt(for: paneId, event: .invalidated)
    }

    func invalidateAll() {
        let activeRecords = Array(records.values)
        records.removeAll()
        for record in activeRecords {
            record.task?.cancel()
            emit(.invalidated, for: record.attempt)
        }
        if !activeRecords.isEmpty {
            onChange()
        }
    }

    private func prepare(_ attempt: Attempt) async {
        guard let record = currentRecord(for: attempt) else { return }
        emit(.cleanupStarted, for: attempt)
        do {
            try await HardOperationDeadline.run(
                timeout: preparationTimeout,
                sleep: sleep,
                operation: { [weak self] in
                    await record.cleanup(attempt)
                    await self?.cleanupDidFinish(attempt)
                }
            )
        } catch is CancellationError {
            return
        } catch HardOperationDeadlineError.exceeded {
            emit(.preparationDeadline, for: attempt)
            // Ownership is removed at cleanup entry. Continue after the hard
            // bound while any transport-specific cleanup finishes separately.
        } catch {
            return
        }

        guard let current = currentRecord(for: attempt) else {
            emit(.staleResultRejected, for: attempt)
            return
        }
        if current.networkIsReady {
            beginConnection(attempt)
        } else {
            waitForNetwork(attempt)
        }
    }

    private func beginConnection(_ attempt: Attempt) {
        guard var record = currentRecord(for: attempt) else { return }
        record.attempt.phase = .connecting
        record.task = nil
        records[attempt.paneId] = record
        emit(.connecting, for: record.attempt)
        onChange()

        record.start(record.attempt)
        guard currentRecord(for: attempt) != nil else { return }

        records[attempt.paneId]?.task = Task { [weak self] in
            guard let self else { return }
            do {
                try await sleep(connectionTimeout)
            } catch {
                return
            }
            await expire(record.attempt)
        }
    }

    private func expire(_ attempt: Attempt) async {
        guard let record = currentRecord(for: attempt) else {
            emit(.staleResultRejected, for: attempt)
            return
        }
        emit(.connectionDeadline, for: record.attempt)
        emit(.cleanupStarted, for: record.attempt)
        do {
            try await HardOperationDeadline.run(
                timeout: preparationTimeout,
                sleep: sleep,
                operation: { [weak self] in
                    await record.cleanup(record.attempt)
                    await self?.cleanupDidFinish(record.attempt)
                }
            )
        } catch HardOperationDeadlineError.exceeded {
            emit(.cleanupDeadline, for: attempt)
            // The failure state is still published at the hard boundary.
        } catch {
            return
        }
        guard let current = currentRecord(for: attempt) else {
            emit(.staleResultRejected, for: attempt)
            return
        }
        records.removeValue(forKey: attempt.paneId)
        current.fail(current.attempt)
        onChange()
    }

    private func currentRecord(for attempt: Attempt) -> Record? {
        guard let record = records[attempt.paneId], record.attempt.id == attempt.id else {
            return nil
        }
        return record
    }

    private func cleanupDidFinish(_ attempt: Attempt) {
        let stage: EventStage = currentRecord(for: attempt) == nil
            ? .staleResultRejected
            : .cleanupCompleted
        emit(stage, for: attempt)
    }

    private func removeAttempt(for paneId: UUID, event: EventStage) {
        guard let record = records.removeValue(forKey: paneId) else { return }
        record.task?.cancel()
        emit(event, for: record.attempt)
        onChange()
    }

    private func waitForNetwork(_ attempt: Attempt) {
        guard var record = currentRecord(for: attempt) else { return }
        record.attempt.phase = .waitingForNetwork
        record.task = nil
        records[attempt.paneId] = record
        emit(.waitingForNetwork, for: record.attempt)
        onChange()
    }

    private func emit(_ stage: EventStage, for attempt: Attempt) {
        onEvent(
            Event(
                attempt: attempt,
                stage: stage,
                systemUptime: Foundation.ProcessInfo.processInfo.systemUptime
            )
        )
    }
}
