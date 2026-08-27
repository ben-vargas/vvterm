import Foundation
import Testing
@testable import VVTerm

@MainActor
struct ServerWakeCoordinatorTests {
    @Test
    func wakeOnlySendsWithoutUsingTheSSHEndpoint() async throws {
        let sender = FixtureWakeOnLANPacketSender()
        let probe = FixtureServerEndpointProbe(results: [])
        let coordinator = makeCoordinator(sender: sender, probe: probe)
        var server = try makeServer()
        server.host = ""
        server.port = 0

        coordinator.start(.wake, for: server)

        #expect(await waitUntil {
            guard case .succeeded(_, .packetSent) = coordinator.phase else {
                return false
            }
            return true
        })
        #expect(await sender.callCount == 1)
        #expect(await probe.calls.isEmpty)
    }

    @Test
    func wakeAndConnectUsesBoundedBackoffUntilSSHIsReachable() async throws {
        let sender = FixtureWakeOnLANPacketSender()
        let probe = FixtureServerEndpointProbe(results: [false, false, true])
        let sleep = RecordingWakeSleep()
        let policy = ServerWakeConnectPolicy(
            probeTimeout: .milliseconds(250),
            retryDelays: [.zero, .milliseconds(10), .milliseconds(20)]
        )
        let coordinator = makeCoordinator(
            sender: sender,
            probe: probe,
            policy: policy,
            sleep: { duration in await sleep.record(duration) }
        )
        let server = try makeServer(host: "  wake.example.test  ", port: 2_222)

        coordinator.start(.wakeAndConnect, for: server)

        #expect(await waitUntil {
            guard case .succeeded(_, .connectionReady) = coordinator.phase else {
                return false
            }
            return true
        })
        #expect(await probe.calls == [
            .init(host: "wake.example.test", port: 2_222, timeout: .milliseconds(250)),
            .init(host: "wake.example.test", port: 2_222, timeout: .milliseconds(250)),
            .init(host: "wake.example.test", port: 2_222, timeout: .milliseconds(250)),
        ])
        #expect(await sleep.durations == [.milliseconds(10), .milliseconds(20)])
    }

    @Test
    func wakeAndConnectReportsTimeoutAfterTheLastProbe() async throws {
        let probe = FixtureServerEndpointProbe(results: [false, false])
        let coordinator = makeCoordinator(
            sender: FixtureWakeOnLANPacketSender(),
            probe: probe,
            policy: ServerWakeConnectPolicy(
                probeTimeout: .seconds(1),
                retryDelays: [.zero, .zero]
            )
        )

        coordinator.start(.wakeAndConnect, for: try makeServer())

        #expect(await waitUntil {
            guard case .failed(_, .timeout) = coordinator.phase else {
                return false
            }
            return true
        })
        #expect(await probe.calls.count == 2)
    }

    @Test
    func cancellationReturnsTheCoordinatorToIdle() async throws {
        let coordinator = makeCoordinator(
            sender: FixtureWakeOnLANPacketSender(),
            probe: FixtureServerEndpointProbe(results: [true]),
            policy: ServerWakeConnectPolicy(
                probeTimeout: .seconds(1),
                retryDelays: [.seconds(60)]
            ),
            sleep: { duration in try await Task.sleep(for: duration) }
        )

        coordinator.start(.wakeAndConnect, for: try makeServer())
        #expect(await waitUntil {
            guard case .waiting = coordinator.phase else { return false }
            return true
        })

        coordinator.cancel()
        for _ in 0..<10 { await Task.yield() }

        #expect(coordinator.phase == .idle)
    }

    @Test
    func replacementSuppressesTheCancelledSendResult() async throws {
        let sender = FirstSendGatePacketSender()
        let coordinator = makeCoordinator(
            sender: sender,
            probe: FixtureServerEndpointProbe(results: [])
        )
        let firstServer = try makeServer(name: "First")
        let secondServer = try makeServer(name: "Second")

        coordinator.start(.wake, for: firstServer)
        await sender.waitUntilFirstSendStarts()
        coordinator.start(.wake, for: secondServer)

        #expect(await waitUntil {
            guard case .succeeded(let operation, .packetSent) = coordinator.phase else {
                return false
            }
            return operation.serverID == secondServer.id
        })

        await sender.releaseFirstSend()
        for _ in 0..<10 { await Task.yield() }

        guard case .succeeded(let operation, .packetSent) = coordinator.phase else {
            Issue.record("Expected the replacement operation to remain successful")
            return
        }
        #expect(operation.serverID == secondServer.id)
    }

    @Test
    func sendFailureKeepsItsActionableError() async throws {
        let coordinator = makeCoordinator(
            sender: FixtureWakeOnLANPacketSender(
                error: .localNetworkAccessDenied
            ),
            probe: FixtureServerEndpointProbe(results: [])
        )

        coordinator.start(.wake, for: try makeServer())

        #expect(await waitUntil {
            guard case .failed(_, .send(.localNetworkAccessDenied)) = coordinator.phase else {
                return false
            }
            return true
        })
    }

    @Test
    func invalidInputsFailBeforeNetworkWork() async throws {
        let sender = FixtureWakeOnLANPacketSender()
        let coordinator = makeCoordinator(
            sender: sender,
            probe: FixtureServerEndpointProbe(results: [])
        )
        let unconfigured = Server(
            workspaceId: UUID(),
            name: "No Wake",
            host: "server.example.test",
            username: "root"
        )

        coordinator.start(.wake, for: unconfigured)
        guard case .failed(_, .notConfigured) = coordinator.phase else {
            Issue.record("Expected missing configuration failure")
            return
        }

        var invalidEndpoint = try makeServer()
        invalidEndpoint.port = 0
        coordinator.start(.wakeAndConnect, for: invalidEndpoint)
        guard case .failed(_, .invalidEndpoint) = coordinator.phase else {
            Issue.record("Expected invalid endpoint failure")
            return
        }

        var invalidHost = try makeServer()
        invalidHost.host = "   "
        coordinator.start(.wakeAndConnect, for: invalidHost)
        guard case .failed(_, .invalidEndpoint) = coordinator.phase else {
            Issue.record("Expected invalid host failure")
            return
        }

        #expect(await sender.callCount == 0)
    }

    @Test
    func readyConnectionCanBeMarkedAsStarted() async throws {
        let coordinator = makeCoordinator(
            sender: FixtureWakeOnLANPacketSender(),
            probe: FixtureServerEndpointProbe(results: [true]),
            policy: ServerWakeConnectPolicy(
                probeTimeout: .seconds(1),
                retryDelays: [.zero]
            )
        )

        coordinator.start(.wakeAndConnect, for: try makeServer())
        #expect(await waitUntil {
            guard case .succeeded(_, .connectionReady) = coordinator.phase else {
                return false
            }
            return true
        })
        let operationID = try #require(coordinator.phase.operation?.id)

        coordinator.markConnectionStarted(operationID: operationID)

        guard case .succeeded(_, .connectionStarted) = coordinator.phase else {
            Issue.record("Expected connection-started state")
            return
        }
    }

    private func makeCoordinator(
        sender: any WakeOnLANPacketSending,
        probe: any ServerEndpointProbing,
        policy: ServerWakeConnectPolicy = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> ServerWakeCoordinator {
        ServerWakeCoordinator(
            dependencies: ServerWakeDependencies(
                sender: sender,
                endpointProbe: probe,
                connectPolicy: policy,
                sleep: sleep,
                makeID: UUID.init
            )
        )
    }

    private func makeServer(
        name: String = "Wakeable",
        host: String = "wake.example.test",
        port: Int = 22
    ) throws -> Server {
        Server(
            workspaceId: UUID(),
            name: name,
            host: host,
            port: port,
            username: "root",
            wakeOnLANConfiguration: try WakeOnLANConfiguration(
                macAddress: WakeOnLANMACAddress("00:11:22:33:44:55")
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

private actor FixtureServerEndpointProbe: ServerEndpointProbing {
    struct Call: Equatable, Sendable {
        let host: String
        let port: UInt16
        let timeout: Duration
    }

    private var results: [Bool]
    private(set) var calls: [Call] = []

    init(results: [Bool]) {
        self.results = results
    }

    func isReachable(host: String, port: UInt16, timeout: Duration) async -> Bool {
        calls.append(Call(host: host, port: port, timeout: timeout))
        return results.isEmpty ? false : results.removeFirst()
    }
}

private actor RecordingWakeSleep {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
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
