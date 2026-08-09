import Foundation
import Testing
@testable import VVTerm

private actor ServerConnectionTesterFake: ServerConnectionTesting {
    private var continuations: [CheckedContinuation<ServerConnectionTestResult, Never>] = []

    func test(server: Server, credentials: ServerCredentials) async -> ServerConnectionTestResult {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForCallCount(_ count: Int) async -> Bool {
        for _ in 0..<2_000 {
            if continuations.count >= count { return true }
            await Task.yield()
        }
        return continuations.count >= count
    }

    func complete(call index: Int, with result: ServerConnectionTestResult) {
        continuations[index].resume(returning: result)
    }
}

private final class ServerHostKeyRepositoryFake: ServerHostKeyRepository, @unchecked Sendable {
    private let lock = NSLock()
    private let challenge: KnownHostsManager.Challenge?
    private var approvedAtStorage: Date?
    private var rejectedStorage: KnownHostsManager.Challenge?

    init(challenge: KnownHostsManager.Challenge? = nil) {
        self.challenge = challenge
    }

    var approvedAt: Date? {
        lock.withLock { approvedAtStorage }
    }

    func pendingChallenge(for host: String, port: Int, now: Date) -> KnownHostsManager.Challenge? {
        challenge
    }

    func approve(_ challenge: KnownHostsManager.Challenge, now: Date) -> Bool {
        lock.withLock { approvedAtStorage = now }
        return true
    }

    func reject(_ challenge: KnownHostsManager.Challenge) {
        lock.withLock { rejectedStorage = challenge }
    }
}

@MainActor
private final class ServerMutationRepositoryGate: ServerMutationRepository {
    private var continuation: CheckedContinuation<Server, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func validate(_ mutation: ServerMutation, hasProAccess: Bool) throws {}

    func apply(_ mutation: ServerMutation) async throws -> Server {
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func succeed(with server: Server) {
        continuation?.resume(returning: server)
        continuation = nil
    }
}

@MainActor
private final class ServerCredentialStoreStub: ServerCredentialStoring {
    func storeCredentials(_ credentials: ServerCredentials, for server: Server) throws {}
}

@Suite(.serialized)
@MainActor
struct ServerFormOperationControllerTests {
    @Test
    func replacementRejectsTheCancelledTestsLateCompletion() async {
        let tester = ServerConnectionTesterFake()
        let controller = makeController(connectionTester: tester)
        let first = makeInput(host: "first.example.com")
        let second = makeInput(host: "second.example.com")

        controller.startConnectionTest(
            server: first.server,
            credentials: first.credentials,
            snapshot: first.snapshot
        )
        #expect(await tester.waitForCallCount(1))

        controller.startConnectionTest(
            server: second.server,
            credentials: second.credentials,
            snapshot: second.snapshot
        )
        #expect(await tester.waitForCallCount(2))

        await tester.complete(call: 0, with: .success)
        for _ in 0..<20 { await Task.yield() }

        guard case .testing(_, let activeSnapshot) = controller.phase else {
            Issue.record("The replacement test is no longer active")
            return
        }
        #expect(activeSnapshot == second.snapshot)

        let failure = ServerConnectionTestFailure(
            message: "Second failed",
            requiresCloudflareOverrides: false,
            hostKeyChallenge: nil
        )
        await tester.complete(call: 1, with: .failure(failure))
        #expect(await waitUntil { controller.connectionTestFailure == failure })
    }

    @Test
    func cancellationRejectsALateConnectionTestCompletion() async {
        let tester = ServerConnectionTesterFake()
        let controller = makeController(connectionTester: tester)
        let input = makeInput(host: "cancelled.example.com")

        controller.startConnectionTest(
            server: input.server,
            credentials: input.credentials,
            snapshot: input.snapshot
        )
        #expect(await tester.waitForCallCount(1))

        controller.cancel()
        await tester.complete(call: 0, with: .success)
        for _ in 0..<20 { await Task.yield() }

        #expect(controller.phase == .idle)
    }

    @Test
    func hostKeyApprovalUsesTheInjectedClockAndRepository() async {
        let fixedNow = Date(timeIntervalSince1970: 42)
        let challenge = KnownHostsManager.Challenge(
            id: UUID(),
            host: "host.example.com",
            port: 22,
            fingerprint: "SHA256:test",
            keyType: 0,
            keyTypeName: "ssh-ed25519",
            kind: .firstUse,
            createdAt: fixedNow
        )
        let tester = ServerConnectionTesterFake()
        let hostKeys = ServerHostKeyRepositoryFake(challenge: challenge)
        let controller = makeController(
            connectionTester: tester,
            hostKeys: hostKeys,
            now: { fixedNow }
        )
        let input = makeInput(host: challenge.host)
        let failure = ServerConnectionTestFailure(
            message: "Approval required",
            requiresCloudflareOverrides: false,
            hostKeyChallenge: challenge
        )

        controller.startConnectionTest(
            server: input.server,
            credentials: input.credentials,
            snapshot: input.snapshot
        )
        #expect(await tester.waitForCallCount(1))
        await tester.complete(call: 0, with: .failure(failure))
        #expect(await waitUntil { controller.hostKeyChallenge == challenge })

        #expect(controller.approveHostKeyChallenge())
        #expect(hostKeys.approvedAt == fixedNow)
        #expect(controller.phase == .idle)
    }

    @Test
    func cancellationRejectsALateSaveCompletion() async {
        let tester = ServerConnectionTesterFake()
        let mutations = ServerMutationRepositoryGate()
        let controller = makeController(
            connectionTester: tester,
            mutations: mutations
        )
        let input = makeInput(host: "save.example.com")
        var savedServer: Server?

        controller.save(
            mutation: .create(input.server),
            credentials: input.credentials,
            hasProAccess: true,
            authorize: { true },
            onSaved: { savedServer = $0 }
        )
        await mutations.waitUntilStarted()

        controller.cancel()
        mutations.succeed(with: input.server)
        for _ in 0..<20 { await Task.yield() }

        #expect(controller.phase == .idle)
        #expect(savedServer == nil)
    }

    private func makeController(
        connectionTester: any ServerConnectionTesting,
        hostKeys: any ServerHostKeyRepository = ServerHostKeyRepositoryFake(),
        mutations: (any ServerMutationRepository)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> ServerFormOperationController {
        ServerFormOperationController(
            connectionTester: connectionTester,
            hostKeys: hostKeys,
            saveUseCase: ServerSaveUseCase(
                mutations: mutations ?? ServerMutationRepositoryGate(),
                credentials: ServerCredentialStoreStub()
            ),
            now: now
        )
    }

    private func makeInput(
        host: String
    ) -> (server: Server, credentials: ServerCredentials, snapshot: ServerFormModel.ConnectionSnapshot) {
        let workspaceID = UUID()
        let serverID = UUID()
        var form = ServerFormModel(
            workspaceID: workspaceID,
            defaultTmuxEnabled: true,
            defaultTmuxStartupBehavior: .vvtermManaged
        )
        form.name = host
        form.host = host
        form.password = "secret"
        return (
            form.makeServer(id: serverID, workspaceID: workspaceID, createdAt: .distantPast),
            form.makeCredentials(serverID: serverID),
            form.connectionSnapshot
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
