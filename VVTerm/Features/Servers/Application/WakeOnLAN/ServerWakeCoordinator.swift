import Combine
import Foundation

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

nonisolated struct ServerWakeDependencies: Sendable {
    let sender: any WakeOnLANPacketSending
    let makeID: @Sendable () -> UUID
}

nonisolated enum ServerWakeFailure: Equatable, Sendable {
    case notConfigured
    case send(WakeOnLANSendError)
    case unexpected
}

nonisolated enum ServerWakePhase: Equatable, Sendable {
    case idle
    case sending(id: UUID)
    case succeeded(id: UUID)
    case failed(id: UUID, ServerWakeFailure)

    var operationID: UUID? {
        switch self {
        case .idle:
            return nil
        case .sending(let id),
             .succeeded(let id),
             .failed(let id, _):
            return id
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

    func start(for server: Server) {
        task?.cancel()
        task = nil

        let operationID = dependencies.makeID()
        guard let configuration = server.wakeOnLANConfiguration else {
            phase = .failed(id: operationID, .notConfigured)
            return
        }

        phase = .sending(id: operationID)
        let sender = dependencies.sender
        task = Task { [weak self] in
            do {
                _ = try await sender.send(configuration: configuration)
                try Task.checkCancellation()
                self?.complete(operationID: operationID)
            } catch is CancellationError {
                return
            } catch let error as WakeOnLANSendError {
                self?.fail(operationID: operationID, with: .send(error))
            } catch {
                self?.fail(operationID: operationID, with: .unexpected)
            }
        }
    }

    func cancel(operationID: UUID? = nil) {
        if let operationID, phase.operationID != operationID {
            return
        }
        task?.cancel()
        task = nil
        phase = .idle
    }

    func dismissOutcome(operationID: UUID) {
        guard phase.operationID == operationID else { return }
        switch phase {
        case .succeeded, .failed:
            phase = .idle
        case .idle, .sending:
            break
        }
    }

    private func complete(operationID: UUID) {
        guard phase.operationID == operationID else { return }
        task = nil
        phase = .succeeded(id: operationID)
    }

    private func fail(
        operationID: UUID,
        with failure: ServerWakeFailure
    ) {
        guard phase.operationID == operationID else { return }
        task = nil
        phase = .failed(id: operationID, failure)
    }
}
