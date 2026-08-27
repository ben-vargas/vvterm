import Foundation
import Testing
@testable import VVTerm

@MainActor
struct ServerWakeCoordinatorTests {
    @Test
    func wakeSendsTheConfiguredPacket() async throws {
        let sender = FixtureWakeOnLANPacketSender()
        let coordinator = makeCoordinator(sender: sender)
        let server = try makeServer()

        coordinator.start(for: server)

        #expect(await waitUntil {
            if case .succeeded = coordinator.phase { return true }
            return false
        })
        #expect(await sender.callCount == 1)
    }

    @Test
    func replacementSuppressesTheCancelledSendResult() async throws {
        let sender = FirstSendGatePacketSender()
        let coordinator = makeCoordinator(sender: sender)
        let firstServer = try makeServer(name: "First")
        let secondServer = try makeServer(name: "Second")

        coordinator.start(for: firstServer)
        await sender.waitUntilFirstSendStarts()
        coordinator.start(for: secondServer)

        #expect(await waitUntil {
            if case .succeeded = coordinator.phase { return true }
            return false
        })
        let replacementOperationID = coordinator.phase.operationID

        await sender.releaseFirstSend()
        for _ in 0..<10 { await Task.yield() }

        guard case .succeeded = coordinator.phase else {
            Issue.record("Expected the replacement operation to remain successful")
            return
        }
        #expect(coordinator.phase.operationID == replacementOperationID)
    }

    @Test
    func cancellationReturnsTheCoordinatorToIdle() async throws {
        let sender = FirstSendGatePacketSender()
        let coordinator = makeCoordinator(sender: sender)

        coordinator.start(for: try makeServer())
        await sender.waitUntilFirstSendStarts()
        coordinator.cancel()
        await sender.releaseFirstSend()
        for _ in 0..<10 { await Task.yield() }

        #expect(coordinator.phase == .idle)
    }

    @Test
    func sendFailureKeepsItsActionableError() async throws {
        let coordinator = makeCoordinator(
            sender: FixtureWakeOnLANPacketSender(
                error: .localNetworkAccessDenied
            )
        )

        coordinator.start(for: try makeServer())

        #expect(await waitUntil {
            guard case .failed(_, .send(.localNetworkAccessDenied)) = coordinator.phase else {
                return false
            }
            return true
        })
    }

    @Test
    func missingConfigurationFailsBeforeNetworkWork() async {
        let sender = FixtureWakeOnLANPacketSender()
        let coordinator = makeCoordinator(sender: sender)
        let server = Server(
            workspaceId: UUID(),
            name: "No Wake",
            host: "server.example.test",
            username: "root"
        )

        coordinator.start(for: server)

        guard case .failed(_, .notConfigured) = coordinator.phase else {
            Issue.record("Expected missing configuration failure")
            return
        }
        #expect(await sender.callCount == 0)
    }

    private func makeCoordinator(
        sender: any WakeOnLANPacketSending
    ) -> ServerWakeCoordinator {
        ServerWakeCoordinator(
            dependencies: ServerWakeDependencies(
                sender: sender,
                makeID: UUID.init
            )
        )
    }

    private func makeServer(name: String = "Wakeable") throws -> Server {
        Server(
            workspaceId: UUID(),
            name: name,
            host: "wake.example.test",
            username: "root",
            wakeOnLANConfiguration: WakeOnLANConfiguration(
                macAddress: try WakeOnLANMACAddress("00:11:22:33:44:55")
            )
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

private actor FixtureWakeOnLANPacketSender: WakeOnLANPacketSending {
    private(set) var callCount = 0
    private let error: WakeOnLANSendError?

    init(error: WakeOnLANSendError? = nil) {
        self.error = error
    }

    func send(
        configuration: WakeOnLANConfiguration
    ) async throws -> WakeOnLANSendReceipt {
        callCount += 1
        if let error { throw error }
        return WakeOnLANSendReceipt(destinations: [])
    }
}

private actor FirstSendGatePacketSender: WakeOnLANPacketSending {
    private var callCount = 0
    private var firstSendStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstSendContinuation: CheckedContinuation<Void, Never>?

    func send(
        configuration: WakeOnLANConfiguration
    ) async throws -> WakeOnLANSendReceipt {
        callCount += 1
        guard callCount == 1 else {
            return WakeOnLANSendReceipt(destinations: [])
        }

        firstSendStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            firstSendContinuation = continuation
        }
        return WakeOnLANSendReceipt(destinations: [])
    }

    func waitUntilFirstSendStarts() async {
        guard !firstSendStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstSend() {
        firstSendContinuation?.resume()
        firstSendContinuation = nil
    }
}
