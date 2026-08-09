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
    private let approvalResult: Bool
    private var approvedAtStorage: Date?
    private var rejectedStorage: KnownHostsManager.Challenge?

    init(
        challenge: KnownHostsManager.Challenge? = nil,
        approvalResult: Bool = true
    ) {
        self.challenge = challenge
        self.approvalResult = approvalResult
    }

    var approvedAt: Date? {
        lock.withLock { approvedAtStorage }
    }

    func pendingChallenge(for host: String, port: Int, now: Date) -> KnownHostsManager.Challenge? {
        challenge
    }

    func approve(_ challenge: KnownHostsManager.Challenge, now: Date) -> Bool {
        lock.withLock { approvedAtStorage = now }
        return approvalResult
    }

    func reject(_ challenge: KnownHostsManager.Challenge) {
        lock.withLock { rejectedStorage = challenge }
    }
}

private final class ServerOperationIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingIDs: [UUID]

    init(_ ids: [UUID]) {
        remainingIDs = ids
    }

    func next() -> UUID {
        lock.withLock {
            precondition(!remainingIDs.isEmpty, "Missing test operation ID")
            return remainingIDs.removeFirst()
        }
    }
}

@MainActor
private final class ServerMutationRepositoryGate: ServerMutationRepository {
    private var continuation: CheckedContinuation<Server, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func validate(_ mutation: ServerMutation, hasProAccess: Bool) throws {}

    func server(id: UUID) -> Server? {
        nil
    }

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
private final class ServerCredentialStoreStub: ServerCredentialTransactionRepository {
    func storeCredentials(_ credentials: ServerCredentials, for server: Server) throws {}

    func getCredentials(for server: Server) throws -> ServerCredentials {
        ServerCredentials(serverId: server.id)
    }

    func deleteCredentials(for serverID: UUID) throws {}
}

@Suite(.serialized)
@MainActor
struct ServerFormOperationControllerTests {
    @Test
    func replacementRejectsTheCancelledTestsLateCompletion() async {
        let firstOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let tester = ServerConnectionTesterFake()
        let controller = makeController(
            connectionTester: tester,
            operationIDs: [firstOperationID, secondOperationID]
        )
        let first = makeInput(host: "first.example.com")
        let second = makeInput(host: "second.example.com")

        controller.startConnectionTest(
            server: first.server,
            credentials: first.credentials,
            snapshot: first.snapshot
        )
        #expect(controller.phase == .testing(id: firstOperationID, snapshot: first.snapshot))
        #expect(await tester.waitForCallCount(1))

        controller.startConnectionTest(
            server: second.server,
            credentials: second.credentials,
            snapshot: second.snapshot
        )
        #expect(await tester.waitForCallCount(2))

        await tester.complete(call: 0, with: .success)
        for _ in 0..<20 { await Task.yield() }

        guard case .testing(let activeID, let activeSnapshot) = controller.phase else {
            Issue.record("The replacement test is no longer active")
            return
        }
        #expect(activeID == secondOperationID)
        #expect(activeSnapshot == second.snapshot)

        let failure = ServerConnectionTestFailure(
            reason: .message("Second failed"),
            requiresCloudflareOverrides: false,
            hostKeyChallenge: nil
        )
        await tester.complete(call: 1, with: .failure(failure))
        #expect(await waitUntil { controller.connectionTestFailure == failure })
    }

    @Test
    func cancellationRejectsALateConnectionTestCompletion() async {
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let tester = ServerConnectionTesterFake()
        let controller = makeController(
            connectionTester: tester,
            operationIDs: [operationID]
        )
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
            now: { fixedNow },
            operationIDs: [UUID(uuidString: "00000000-0000-0000-0000-000000000004")!]
        )
        let input = makeInput(host: challenge.host)
        let failure = ServerConnectionTestFailure(
            reason: .message("Approval required"),
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
    func expiredHostKeyApprovalStoresASemanticFailureReason() async {
        let challenge = KnownHostsManager.Challenge(
            id: UUID(),
            host: "expired.example.com",
            port: 22,
            fingerprint: "SHA256:expired",
            keyType: 0,
            keyTypeName: "ssh-ed25519",
            kind: .firstUse,
            createdAt: .distantPast
        )
        let tester = ServerConnectionTesterFake()
        let controller = makeController(
            connectionTester: tester,
            hostKeys: ServerHostKeyRepositoryFake(
                challenge: challenge,
                approvalResult: false
            ),
            operationIDs: [UUID(uuidString: "00000000-0000-0000-0000-000000000005")!]
        )
        let input = makeInput(host: challenge.host)
        let approvalRequired = ServerConnectionTestFailure(
            reason: .message("Approval required"),
            requiresCloudflareOverrides: false,
            hostKeyChallenge: challenge
        )

        controller.startConnectionTest(
            server: input.server,
            credentials: input.credentials,
            snapshot: input.snapshot
        )
        #expect(await tester.waitForCallCount(1))
        await tester.complete(call: 0, with: .failure(approvalRequired))
        #expect(await waitUntil { controller.hostKeyChallenge == challenge })

        #expect(!controller.approveHostKeyChallenge())
        #expect(
            controller.connectionTestFailure?.reason == .hostKeyApprovalExpired
        )
    }

    @Test
    func credentialEndpointApprovalIsAnExplicitDismissiblePhase() {
        let controller = makeController(
            connectionTester: ServerConnectionTesterFake(),
            operationIDs: []
        )

        controller.requireCredentialApproval()

        #expect(controller.phase == .credentialApprovalRequired)
        #expect(controller.credentialApprovalRequired)

        controller.clearPresentation()
        #expect(controller.phase == .idle)
    }

    @Test
    func cancellationRejectsALateSaveCompletion() async {
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        let tester = ServerConnectionTesterFake()
        let mutations = ServerMutationRepositoryGate()
        let controller = makeController(
            connectionTester: tester,
            mutations: mutations,
            operationIDs: [operationID]
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
        #expect(controller.phase == .saving(id: operationID))
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
        now: @escaping @Sendable () -> Date = { .distantPast },
        operationIDs: [UUID]
    ) -> ServerFormOperationController {
        let idSequence = ServerOperationIDSequence(operationIDs)
        return ServerFormOperationController(
            connectionTester: connectionTester,
            hostKeys: hostKeys,
            saveUseCase: ServerSaveUseCase(
                mutations: mutations ?? ServerMutationRepositoryGate(),
                credentials: ServerCredentialStoreStub()
            ),
            now: now,
            makeID: { idSequence.next() }
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
