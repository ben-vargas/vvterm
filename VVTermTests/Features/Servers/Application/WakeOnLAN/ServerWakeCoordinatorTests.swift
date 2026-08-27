import Foundation
import Testing
@testable import VVTerm

@MainActor
struct ServerWakeCoordinatorTests {
    @Test
    func wakeSendsTheConfiguredPacketWithoutResolvingAgain() async throws {
        let sender = FixtureWakeOnLANPacketSender()
        let resolver = FixtureWakeOnLANMACAddressResolver()
        let server = try makeServer()
        let (coordinator, mutations) = makeCoordinator(
            sender: sender,
            resolver: resolver,
            servers: [server]
        )

        coordinator.start(for: server)

        #expect(await waitUntil {
            if case .succeeded = coordinator.phase { return true }
            return false
        })
        #expect(await sender.callCount == 1)
        #expect(resolver.callCount == 0)
        #expect(mutations.applyCount == 0)
    }

    @Test
    func missingConfigurationIsDetectedPersistedAndSent() async throws {
        let sender = FixtureWakeOnLANPacketSender()
        let resolver = FixtureWakeOnLANMACAddressResolver(
            address: try WakeOnLANMACAddress("AA:BB:CC:DD:EE:FF")
        )
        let server = makeServerWithoutConfiguration()
        let (coordinator, mutations) = makeCoordinator(
            sender: sender,
            resolver: resolver,
            servers: [server]
        )

        coordinator.start(for: server)

        #expect(await waitUntil {
            if case .succeeded = coordinator.phase { return true }
            return false
        })
        #expect(resolver.callCount == 1)
        #expect(await sender.callCount == 1)
        #expect(mutations.applyCount == 1)
        #expect(
            mutations.server(id: server.id)?
                .wakeOnLANConfiguration?.macAddress.canonicalValue
                == "AA:BB:CC:DD:EE:FF"
        )
    }

    @Test
    func addressDetectionFailureStopsBeforePacketDelivery() async {
        let sender = FixtureWakeOnLANPacketSender()
        let resolver = FixtureWakeOnLANMACAddressResolver(address: nil)
        let server = makeServerWithoutConfiguration()
        let (coordinator, mutations) = makeCoordinator(
            sender: sender,
            resolver: resolver,
            servers: [server]
        )

        coordinator.start(for: server)

        #expect(await waitUntil {
            guard case .failed(_, .macAddressUnavailable) = coordinator.phase else {
                return false
            }
            return true
        })
        #expect(await sender.callCount == 0)
        #expect(mutations.applyCount == 0)
    }

    @Test
    func automaticWakeStartsOnlyForAnEnabledServer() async throws {
        let sender = FixtureWakeOnLANPacketSender()
        var server = try makeServer()
        let (coordinator, _) = makeCoordinator(sender: sender, servers: [server])

        coordinator.startAutomaticallyIfEnabled(for: server)
        #expect(coordinator.phase == .idle)
        #expect(await sender.callCount == 0)

        server.autoWakeOnLANEnabled = true
        coordinator.startAutomaticallyIfEnabled(for: server)

        #expect(await waitUntil {
            if case .succeeded = coordinator.phase { return true }
            return false
        })
        #expect(await sender.callCount == 1)
    }

    @Test
    func replacementSuppressesTheCancelledSendResult() async throws {
        let sender = FirstSendGatePacketSender()
        let firstServer = try makeServer(name: "First")
        let secondServer = try makeServer(name: "Second")
        let (coordinator, _) = makeCoordinator(
            sender: sender,
            servers: [firstServer, secondServer]
        )

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
        let server = try makeServer()
        let (coordinator, _) = makeCoordinator(sender: sender, servers: [server])

        coordinator.start(for: server)
        await sender.waitUntilFirstSendStarts()
        coordinator.cancel()
        await sender.releaseFirstSend()
        for _ in 0..<10 { await Task.yield() }

        #expect(coordinator.phase == .idle)
    }

    @Test
    func sendFailureKeepsItsActionableError() async throws {
        let server = try makeServer()
        let (coordinator, _) = makeCoordinator(
            sender: FixtureWakeOnLANPacketSender(
                error: .localNetworkAccessDenied
            ),
            servers: [server]
        )

        coordinator.start(for: server)

        #expect(await waitUntil {
            guard case .failed(_, .send(.localNetworkAccessDenied)) = coordinator.phase else {
                return false
            }
            return true
        })
    }

    private func makeCoordinator(
        sender: any WakeOnLANPacketSending,
        resolver: FixtureWakeOnLANMACAddressResolver = FixtureWakeOnLANMACAddressResolver(),
        servers: [Server]
    ) -> (ServerWakeCoordinator, WakeServerMutationRepositoryFake) {
        let mutations = WakeServerMutationRepositoryFake(servers: servers)
        let credentials = WakeServerCredentialRepositoryFake(servers: servers)
        return (
            ServerWakeCoordinator(
                dependencies: ServerWakeDependencies(
                    sender: sender,
                    macAddressResolver: resolver,
                    mutations: mutations,
                    credentials: credentials,
                    makeID: UUID.init
                )
            ),
            mutations
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

    private func makeServerWithoutConfiguration() -> Server {
        Server(
            workspaceId: UUID(),
            name: "No cached address",
            host: "wake.example.test",
            username: "root"
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

private enum FixtureWakeOnLANMACAddressResolutionError: Error {
    case unavailable
}

private final class FixtureWakeOnLANMACAddressResolver: WakeOnLANMACAddressResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var callCountStorage = 0
    private let address: WakeOnLANMACAddress?

    var callCount: Int {
        lock.withLock { callCountStorage }
    }

    init(
        address: WakeOnLANMACAddress? = try! WakeOnLANMACAddress("00:11:22:33:44:55")
    ) {
        self.address = address
    }

    func resolveMACAddress(
        for server: Server,
        credentials: ServerCredentials
    ) async throws -> WakeOnLANMACAddress {
        lock.withLock { callCountStorage += 1 }
        guard let address else {
            throw FixtureWakeOnLANMACAddressResolutionError.unavailable
        }
        return address
    }
}

@MainActor
private final class WakeServerMutationRepositoryFake: ServerMutationRepository {
    private var serversByID: [UUID: Server]
    private(set) var applyCount = 0

    init(servers: [Server]) {
        serversByID = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
    }

    func validate(_ mutation: ServerMutation, hasProAccess: Bool) throws {}

    func server(id: UUID) -> Server? {
        serversByID[id]
    }

    func apply(
        _ mutation: ServerMutation,
        credentials: ServerCredentials
    ) async throws -> Server {
        applyCount += 1
        let server = mutation.server
        serversByID[server.id] = server
        return server
    }
}

@MainActor
private final class WakeServerCredentialRepositoryFake: ServerCredentialRepository {
    private var credentialsByServerID: [UUID: ServerCredentials]

    init(servers: [Server]) {
        credentialsByServerID = Dictionary(uniqueKeysWithValues: servers.map {
            ($0.id, ServerCredentials(serverId: $0.id))
        })
    }

    func storeCredentials(_ credentials: ServerCredentials, for server: Server) throws {
        credentialsByServerID[server.id] = credentials
    }

    func getCredentials(for server: Server) throws -> ServerCredentials {
        credentialsByServerID[server.id] ?? ServerCredentials(serverId: server.id)
    }

    func deleteCredentials(for serverID: UUID) throws {
        credentialsByServerID[serverID] = nil
    }

    func getStoredSSHKeys() -> [SSHKeyEntry] { [] }

    func getStoredSSHKeyData(for id: UUID) throws -> (key: Data, passphrase: String?)? {
        nil
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
    ) async throws {
        callCount += 1
        if let error { throw error }
    }
}

private actor FirstSendGatePacketSender: WakeOnLANPacketSending {
    private var callCount = 0
    private var firstSendStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstSendContinuation: CheckedContinuation<Void, Never>?

    func send(
        configuration: WakeOnLANConfiguration
    ) async throws {
        callCount += 1
        guard callCount == 1 else {
            return
        }

        firstSendStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            firstSendContinuation = continuation
        }
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
