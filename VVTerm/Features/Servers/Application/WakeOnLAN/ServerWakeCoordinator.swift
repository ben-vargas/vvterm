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

nonisolated protocol WakeOnLANPacketSending: Sendable {
    func send(configuration: WakeOnLANConfiguration) async throws
}

@MainActor
struct ServerWakeDependencies {
    let sender: any WakeOnLANPacketSending
    let macAddressResolver: any WakeOnLANMACAddressResolving
    let mutations: any ServerMutationRepository
    let credentials: any ServerCredentialRepository
    let makeID: @Sendable () -> UUID
}

nonisolated enum ServerWakeFailure: Equatable, Sendable {
    case macAddressUnavailable
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

        let operationID = dependencies.makeID()
        phase = .sending(id: operationID)
        let dependencies = dependencies
        task = Task { [weak self] in
            let configuration: WakeOnLANConfiguration
            do {
                configuration = try await Self.configuration(
                    for: server,
                    dependencies: dependencies
                )
            } catch is CancellationError {
                return
            } catch is ServerWakePreparationError {
                self?.fail(operationID: operationID, with: .macAddressUnavailable)
                return
            } catch {
                self?.fail(operationID: operationID, with: .unexpected)
                return
            }

            do {
                try await dependencies.sender.send(configuration: configuration)
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

    func startAutomaticallyIfEnabled(for server: Server) {
        guard server.autoWakeOnLANEnabled else { return }
        start(for: server)
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

    private static func configuration(
        for server: Server,
        dependencies: ServerWakeDependencies
    ) async throws -> WakeOnLANConfiguration {
        guard var currentServer = dependencies.mutations.server(id: server.id) else {
            throw VVTermError.serverNotFound
        }
        if let configuration = currentServer.wakeOnLANConfiguration {
            return configuration
        }

        let credentials: ServerCredentials
        let macAddress: WakeOnLANMACAddress
        do {
            credentials = try dependencies.credentials.getCredentials(for: currentServer)
            macAddress = try await dependencies.macAddressResolver.resolveMACAddress(
                for: currentServer,
                credentials: credentials
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ServerWakePreparationError.macAddressUnavailable
        }
        try Task.checkCancellation()

        let configuration = WakeOnLANConfiguration(macAddress: macAddress)
        currentServer.wakeOnLANConfiguration = configuration
        let savedServer = try await dependencies.mutations.apply(
            .update(currentServer),
            credentials: credentials
        )
        return savedServer.wakeOnLANConfiguration ?? configuration
    }
}

private enum ServerWakePreparationError: Error {
    case macAddressUnavailable
}
