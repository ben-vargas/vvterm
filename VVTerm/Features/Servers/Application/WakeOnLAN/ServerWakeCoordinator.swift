import Combine
import Foundation

nonisolated enum ServerWakeAction: Equatable, Sendable {
    case wake
    case wakeAndConnect
}

nonisolated struct ServerWakeOperation: Equatable, Identifiable, Sendable {
    let id: UUID
    let serverID: UUID
    let action: ServerWakeAction
}

nonisolated enum ServerWakeSuccess: Equatable, Sendable {
    case packetSent
    case connectionReady
    case connectionStarted
}

nonisolated enum WakeOnLANSendError: Error, Equatable, Sendable {
    case localNetworkAccessDenied
    case interfaceEnumerationFailed(code: Int32)
    case noEligibleNetworkInterface
    case socketCreationFailed(code: Int32)
    case broadcastConfigurationFailed(code: Int32)
    case destinationEncodingFailed(address: String)
    case datagramSendFailed(address: String, code: Int32)
    case incompleteDatagram(address: String, expected: Int, actual: Int)
}

nonisolated struct WakeOnLANSendReceipt: Equatable, Sendable {
    let destinations: [WakeOnLANIPv4Address]
}

nonisolated protocol WakeOnLANPacketSending: Sendable {
    func send(configuration: WakeOnLANConfiguration) async throws -> WakeOnLANSendReceipt
}

nonisolated protocol ServerEndpointProbing: Sendable {
    func isReachable(host: String, port: UInt16, timeout: Duration) async -> Bool
}

nonisolated struct ServerWakeConnectPolicy: Equatable, Sendable {
    let probeTimeout: Duration
    let retryDelays: [Duration]

    static let standard = ServerWakeConnectPolicy(
        probeTimeout: .seconds(1),
        retryDelays: [
            .zero,
            .seconds(1),
            .seconds(2),
            .seconds(3),
            .seconds(5),
            .seconds(5),
            .seconds(5),
            .seconds(5),
            .seconds(5)
        ]
    )
}

nonisolated struct ServerWakeDependencies: Sendable {
    let sender: any WakeOnLANPacketSending
    let endpointProbe: any ServerEndpointProbing
    let connectPolicy: ServerWakeConnectPolicy
    let sleep: @Sendable (Duration) async throws -> Void
    let makeID: @Sendable () -> UUID
}

nonisolated enum ServerWakeFailure: Equatable, Sendable {
    case notConfigured
    case invalidEndpoint
    case send(WakeOnLANSendError)
    case timeout
    case unexpected
}

nonisolated enum ServerWakePhase: Equatable, Sendable {
    case idle
    case sending(ServerWakeOperation)
    case waiting(
        ServerWakeOperation,
        attempt: Int,
        totalAttempts: Int
    )
    case succeeded(ServerWakeOperation, ServerWakeSuccess)
    case failed(ServerWakeOperation, ServerWakeFailure)

    var operation: ServerWakeOperation? {
        switch self {
        case .idle:
            return nil
        case .sending(let operation),
             .waiting(let operation, _, _),
             .succeeded(let operation, _),
             .failed(let operation, _):
            return operation
        }
    }
}

@MainActor
final class ServerWakeCoordinator: ObservableObject {
    @Published private(set) var phase: ServerWakePhase = .idle

    private let dependencies: ServerWakeDependencies
    private var task: Task<Void, Never>?

    init(dependencies: ServerWakeDependencies) {
        self.dependencies = dependencies
    }

    deinit {
        task?.cancel()
    }

    func start(_ action: ServerWakeAction, for server: Server) {
        task?.cancel()
        task = nil

        let operation = ServerWakeOperation(
            id: dependencies.makeID(),
            serverID: server.id,
            action: action
        )

        guard let configuration = server.wakeOnLANConfiguration else {
            phase = .failed(operation, .notConfigured)
            return
        }
        let endpointHost = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointPort: UInt16?
        if action == .wakeAndConnect {
            endpointPort = UInt16(exactly: server.port).flatMap { $0 > 0 ? $0 : nil }
            guard endpointPort != nil, !endpointHost.isEmpty else {
                phase = .failed(operation, .invalidEndpoint)
                return
            }
        } else {
            endpointPort = nil
        }

        phase = .sending(operation)
        let sender = dependencies.sender
        let endpointProbe = dependencies.endpointProbe
        let policy = dependencies.connectPolicy
        let sleep = dependencies.sleep

        task = Task { [weak self] in
            do {
                _ = try await sender.send(configuration: configuration)
                try Task.checkCancellation()
                guard self?.isCurrent(operation.id) == true else { return }

                if action == .wake {
                    self?.complete(operation, with: .packetSent)
                    return
                }
                guard let endpointPort else { return }

                for (offset, delay) in policy.retryDelays.enumerated() {
                    let attempt = offset + 1
                    self?.setWaiting(
                        operation,
                        attempt: attempt,
                        totalAttempts: policy.retryDelays.count
                    )

                    if delay > .zero {
                        try await sleep(delay)
                    }
                    try Task.checkCancellation()
                    guard self?.isCurrent(operation.id) == true else { return }

                    let isReachable = await endpointProbe.isReachable(
                        host: endpointHost,
                        port: endpointPort,
                        timeout: policy.probeTimeout
                    )
                    try Task.checkCancellation()
                    guard self?.isCurrent(operation.id) == true else { return }
                    if isReachable {
                        self?.complete(operation, with: .connectionReady)
                        return
                    }
                }

                self?.fail(operation, with: .timeout)
            } catch is CancellationError {
                return
            } catch let error as WakeOnLANSendError {
                self?.fail(operation, with: .send(error))
            } catch {
                self?.fail(operation, with: .unexpected)
            }
        }
    }

    func cancel(operationID: UUID? = nil) {
        if let operationID, phase.operation?.id != operationID {
            return
        }
        task?.cancel()
        task = nil
        phase = .idle
    }

    func markConnectionStarted(operationID: UUID) {
        guard case .succeeded(let operation, .connectionReady) = phase,
              operation.id == operationID else {
            return
        }
        phase = .succeeded(operation, .connectionStarted)
    }

    func dismissOutcome(operationID: UUID) {
        guard phase.operation?.id == operationID else { return }
        switch phase {
        case .succeeded, .failed:
            phase = .idle
        default:
            break
        }
    }

    private func isCurrent(_ operationID: UUID) -> Bool {
        phase.operation?.id == operationID
    }

    private func setWaiting(
        _ operation: ServerWakeOperation,
        attempt: Int,
        totalAttempts: Int
    ) {
        guard isCurrent(operation.id) else { return }
        phase = .waiting(
            operation,
            attempt: attempt,
            totalAttempts: totalAttempts
        )
    }

    private func complete(
        _ operation: ServerWakeOperation,
        with success: ServerWakeSuccess
    ) {
        guard isCurrent(operation.id) else { return }
        task = nil
        phase = .succeeded(operation, success)
    }

    private func fail(
        _ operation: ServerWakeOperation,
        with failure: ServerWakeFailure
    ) {
        guard isCurrent(operation.id) else { return }
        task = nil
        phase = .failed(operation, failure)
    }
}
