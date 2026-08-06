#if os(macOS) && DEBUG
import Combine
import SwiftUI

@MainActor
final class MacTerminalRecoveryUITestHarnessModel: ObservableObject {
    enum Outcome: Equatable {
        case idle
        case waitingForNetwork
        case reconnecting
        case connected
        case failed
    }

    @Published private(set) var outcome: Outcome = .idle
    var simulatedInterval: TimeInterval { Self.simulatedSleepInterval }
    private(set) var cleanupCount = 0
    private(set) var replacementCount = 0
    private(set) var staleCompletionCount = 0
    private(set) var observedOutcomes: Set<Outcome> = [.idle]
    private(set) var lastAttemptStartedAt: Date?

    nonisolated private static let simulatedSleepInterval: TimeInterval = 8 * 60 * 60
    private let paneId = UUID()
    private let simulatesSuccess: Bool
    private let cleanupBlocker = MacTerminalRecoveryHarnessBlocker()
    private var recoveryGate = MacTerminalRecoveryGate()
    private lazy var coordinator = TerminalReconnectCoordinator(
        preparationTimeout: .milliseconds(20),
        connectionTimeout: .milliseconds(30),
        now: { Date(timeIntervalSince1970: Self.simulatedSleepInterval) },
        onEvent: { [weak self] event in
            if event.stage == .staleResultRejected {
                self?.staleCompletionCount += 1
            }
        },
        onChange: {}
    )

    init(simulatesSuccess: Bool) {
        self.simulatesSuccess = simulatesSuccess
    }

    func run() {
        guard outcome == .idle || outcome == .failed else { return }
        setOutcome(.waitingForNetwork)

        _ = recoveryGate.receive(.sleep, networkReadiness: .unavailable)
        guard case .waitForNetwork(let generation) = recoveryGate.receive(
            .wake,
            networkReadiness: .unavailable
        ) else {
            setOutcome(.failed)
            return
        }

        let attempt = coordinator.request(
            paneId: paneId,
            generation: generation,
            networkIsReady: false,
            replacingCurrent: true,
            cleanup: { [weak self] _ in
                guard let self else { return }
                cleanupCount += 1
                await cleanupBlocker.wait()
            },
            start: { [weak self] attempt in
                guard let self else { return }
                replacementCount += 1
                setOutcome(.reconnecting)
                guard simulatesSuccess else { return }
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(2))
                    guard let self,
                          coordinator.attempt(for: attempt.paneId)?.id == attempt.id else {
                        return
                    }
                    setOutcome(.connected)
                    coordinator.complete(for: attempt.paneId)
                    await cleanupBlocker.release()
                }
            },
            fail: { [weak self] _ in
                guard let self else { return }
                setOutcome(.failed)
                Task { await self.cleanupBlocker.release() }
            }
        )
        lastAttemptStartedAt = attempt?.startedAt

        guard recoveryGate.receive(
            .networkChanged(.ready),
            networkReadiness: .ready
        ) == .recover(generation) else {
            setOutcome(.failed)
            return
        }
        coordinator.networkBecameReady(for: generation)

        // Duplicate wake, activation, and ready notifications must not create
        // another replacement for this sleep generation.
        _ = recoveryGate.receive(.wake, networkReadiness: .ready)
        _ = recoveryGate.receive(.applicationActivated, networkReadiness: .ready)
        _ = recoveryGate.receive(.networkChanged(.ready), networkReadiness: .ready)
    }

    private func setOutcome(_ outcome: Outcome) {
        self.outcome = outcome
        observedOutcomes.insert(outcome)
    }
}

private actor MacTerminalRecoveryHarnessBlocker {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isReleased = true
        let activeWaiters = waiters
        waiters.removeAll()
        activeWaiters.forEach { $0.resume() }
    }
}

struct MacTerminalRecoveryUITestHarness: View {
    @StateObject private var model: MacTerminalRecoveryUITestHarnessModel

    init(simulatesSuccess: Bool) {
        _model = StateObject(
            wrappedValue: MacTerminalRecoveryUITestHarnessModel(
                simulatesSuccess: simulatesSuccess
            )
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            switch model.outcome {
            case .idle, .reconnecting:
                ProgressView("Reconnecting…")
            case .waitingForNetwork:
                ProgressView("Waiting for network…")
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
            case .failed:
                Text("Connection timed out. Please retry.")
                Button("Retry") { model.run() }
                    .accessibilityIdentifier("vvterm.macRecovery.retry")
            }

            Text("simulatedSleepHours=\(Int(model.simulatedInterval / 3_600))")
                .font(.caption.monospaced())
        }
        .frame(minWidth: 420, minHeight: 240)
        .accessibilityIdentifier("vvterm.macRecovery.\(String(describing: model.outcome))")
        .task { model.run() }
    }
}
#endif
