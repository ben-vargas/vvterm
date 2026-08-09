import Foundation
import XCTest
@testable import VVTerm

private enum StatsConnectionTestError: Error {
    case failed
}

private actor StatsConnectionGate {
    struct Start: Equatable {
        let serverID: UUID
        let disconnectWhenDone: Bool
    }

    private var starts: [ObjectIdentifier: Start] = [:]
    private var pending: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]
    private var cancelled: Set<ObjectIdentifier> = []
    private var exited: Set<ObjectIdentifier> = []
    private var startWaiters: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]
    private var cancellationWaiters: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]
    private var exitWaiters: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]

    func run(
        client: SSHClient,
        serverID: UUID,
        disconnectWhenDone: Bool
    ) async throws {
        let clientID = ObjectIdentifier(client)
        starts[clientID] = Start(
            serverID: serverID,
            disconnectWhenDone: disconnectWhenDone
        )
        startWaiters.removeValue(forKey: clientID)?.forEach { $0.resume() }

        defer {
            exited.insert(clientID)
            exitWaiters.removeValue(forKey: clientID)?.forEach { $0.resume() }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[clientID] = continuation
            }
        } onCancel: {
            Task { await self.recordCancellation(for: clientID) }
        }
    }

    func waitUntilStarted(_ client: SSHClient) async {
        let clientID = ObjectIdentifier(client)
        guard starts[clientID] == nil else { return }
        await withCheckedContinuation { continuation in
            startWaiters[clientID, default: []].append(continuation)
        }
    }

    func waitUntilCancelled(_ client: SSHClient) async {
        let clientID = ObjectIdentifier(client)
        guard !cancelled.contains(clientID) else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters[clientID, default: []].append(continuation)
        }
    }

    func waitUntilExited(_ client: SSHClient) async {
        let clientID = ObjectIdentifier(client)
        guard !exited.contains(clientID) else { return }
        await withCheckedContinuation { continuation in
            exitWaiters[clientID, default: []].append(continuation)
        }
    }

    func start(for client: SSHClient) -> Start? {
        starts[ObjectIdentifier(client)]
    }

    func wasCancelled(_ client: SSHClient) -> Bool {
        cancelled.contains(ObjectIdentifier(client))
    }

    func succeed(_ client: SSHClient) {
        pending.removeValue(forKey: ObjectIdentifier(client))?.resume()
    }

    func fail(_ client: SSHClient) {
        pending.removeValue(forKey: ObjectIdentifier(client))?.resume(
            throwing: StatsConnectionTestError.failed
        )
    }

    private func recordCancellation(for clientID: ObjectIdentifier) {
        cancelled.insert(clientID)
        cancellationWaiters.removeValue(forKey: clientID)?.forEach { $0.resume() }
    }
}

@MainActor
private final class StatsClientFactory {
    private(set) var clients: [SSHClient] = []

    func makeClient() -> SSHClient {
        let client = SSHClient()
        clients.append(client)
        return client
    }
}

@MainActor
final class ServerStatsCollectorLifecycleTests: XCTestCase {
    func testRepeatedOwnedStartIsIdempotentAndUpdatesDockerPolicy() async throws {
        let gate = StatsConnectionGate()
        let factory = StatsClientFactory()
        let collector = makeCollector(factory: factory, gate: gate)
        let server = makeServer()

        await collector.startCollecting(for: server, collectDocker: false)
        let client = try XCTUnwrap(factory.clients.first)
        await gate.waitUntilStarted(client)
        let firstAttemptID = try XCTUnwrap(collector.collectionState.phase.attemptID)

        await collector.startCollecting(for: server, collectDocker: true)

        XCTAssertEqual(collector.collectionState.phase.attemptID, firstAttemptID)
        XCTAssertEqual(factory.clients.count, 1)
        XCTAssertTrue(collector.isDockerCollectionEnabled)
        let wasCancelled = await gate.wasCancelled(client)
        XCTAssertFalse(wasCancelled)

        collector.stopCollecting()
        await gate.waitUntilCancelled(client)
        await gate.succeed(client)
    }

    func testDifferentServerClientAndOwnershipReplaceActiveAttempt() async throws {
        let gate = StatsConnectionGate()
        let factory = StatsClientFactory()
        let collector = makeCollector(factory: factory, gate: gate)
        let firstServer = makeServer()
        let secondServer = makeServer()
        let firstSharedClient = SSHClient()
        let secondSharedClient = SSHClient()

        await collector.startCollecting(for: firstServer, using: firstSharedClient)
        await gate.waitUntilStarted(firstSharedClient)
        let firstAttemptID = try XCTUnwrap(collector.collectionState.phase.attemptID)
        let sharedStart = await gate.start(for: firstSharedClient)
        XCTAssertEqual(sharedStart?.disconnectWhenDone, false)

        await collector.startCollecting(
            for: firstServer,
            using: firstSharedClient,
            collectDocker: true
        )
        XCTAssertEqual(collector.collectionState.phase.attemptID, firstAttemptID)
        XCTAssertTrue(collector.isDockerCollectionEnabled)
        let sharedWasCancelled = await gate.wasCancelled(firstSharedClient)
        XCTAssertFalse(sharedWasCancelled)

        await collector.startCollecting(for: firstServer, using: secondSharedClient)
        await gate.waitUntilCancelled(firstSharedClient)
        await gate.waitUntilStarted(secondSharedClient)
        let secondAttemptID = try XCTUnwrap(collector.collectionState.phase.attemptID)
        XCTAssertNotEqual(secondAttemptID, firstAttemptID)

        await collector.startCollecting(for: firstServer)
        let firstOwnedClient = try XCTUnwrap(factory.clients.first)
        await gate.waitUntilCancelled(secondSharedClient)
        await gate.waitUntilStarted(firstOwnedClient)
        let thirdAttemptID = try XCTUnwrap(collector.collectionState.phase.attemptID)
        XCTAssertNotEqual(thirdAttemptID, secondAttemptID)
        let ownedStart = await gate.start(for: firstOwnedClient)
        XCTAssertEqual(ownedStart?.disconnectWhenDone, true)

        await collector.startCollecting(for: secondServer)
        let secondOwnedClient = try XCTUnwrap(factory.clients.last)
        await gate.waitUntilCancelled(firstOwnedClient)
        await gate.waitUntilStarted(secondOwnedClient)
        XCTAssertNotEqual(collector.collectionState.phase.attemptID, thirdAttemptID)
        XCTAssertEqual(factory.clients.count, 2)

        collector.stopCollecting()
        await gate.waitUntilCancelled(secondOwnedClient)
        await gate.succeed(firstSharedClient)
        await gate.succeed(secondSharedClient)
        await gate.succeed(firstOwnedClient)
        await gate.succeed(secondOwnedClient)
    }

    func testStopCancelsActiveAttempt() async throws {
        let gate = StatsConnectionGate()
        let factory = StatsClientFactory()
        let collector = makeCollector(factory: factory, gate: gate)
        let client = SSHClient()

        await collector.startCollecting(for: makeServer(), using: client)
        await gate.waitUntilStarted(client)

        collector.stopCollecting()

        await gate.waitUntilCancelled(client)
        XCTAssertEqual(collector.collectionState.phase, .idle)
        XCTAssertFalse(collector.isCollecting)
        XCTAssertNil(collector.connectionError)
        await gate.succeed(client)
    }

    func testStaleCompletionCannotMutateReplacementAttempt() async throws {
        let gate = StatsConnectionGate()
        let factory = StatsClientFactory()
        let collector = makeCollector(factory: factory, gate: gate)
        let server = makeServer()
        let firstClient = SSHClient()
        let replacementClient = SSHClient()

        await collector.startCollecting(for: server, using: firstClient)
        await gate.waitUntilStarted(firstClient)

        await collector.startCollecting(for: server, using: replacementClient)
        await gate.waitUntilCancelled(firstClient)
        await gate.waitUntilStarted(replacementClient)
        let replacementAttemptID = try XCTUnwrap(collector.collectionState.phase.attemptID)

        await gate.fail(firstClient)
        await gate.waitUntilExited(firstClient)
        await Task.yield()

        XCTAssertEqual(
            collector.collectionState.phase,
            .starting(attemptID: replacementAttemptID)
        )
        XCTAssertNil(collector.connectionError)

        collector.stopCollecting()
        await gate.waitUntilCancelled(replacementClient)
        await gate.succeed(replacementClient)
    }

    private func makeCollector(
        factory: StatsClientFactory,
        gate: StatsConnectionGate
    ) -> ServerStatsCollector {
        ServerStatsCollector(
            makeClient: { factory.makeClient() },
            runWithConnection: { client, server, _, disconnectWhenDone, _ in
                try await gate.run(
                    client: client,
                    serverID: server.id,
                    disconnectWhenDone: disconnectWhenDone
                )
            }
        )
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Stats Test",
            host: "stats.example.com",
            username: "tester",
            connectionMode: .tailscale
        )
    }
}
