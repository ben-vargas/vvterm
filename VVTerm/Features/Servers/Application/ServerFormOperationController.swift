import Combine
import Foundation

nonisolated enum ServerConnectionTestFailureReason: Equatable, Sendable {
    case message(String)
    case hostKeyApprovalExpired
}

nonisolated struct ServerConnectionTestFailure: Equatable, Sendable {
    let reason: ServerConnectionTestFailureReason
    let requiresCloudflareOverrides: Bool
    let hostKeyChallenge: KnownHostsManager.Challenge?
}

nonisolated enum ServerConnectionTestResult: Equatable, Sendable {
    case success
    case failure(ServerConnectionTestFailure)
    case cancelled
}

nonisolated protocol ServerConnectionTesting: Sendable {
    func test(server: Server, credentials: ServerCredentials) async -> ServerConnectionTestResult
}

nonisolated protocol ServerHostKeyRepository: Sendable {
    func pendingChallenge(for host: String, port: Int, now: Date) -> KnownHostsManager.Challenge?
    func approve(_ challenge: KnownHostsManager.Challenge, now: Date) -> Bool
    func reject(_ challenge: KnownHostsManager.Challenge)
}

nonisolated enum ServerFormOperationPhase: Equatable, Sendable {
    case idle
    case loadingCredentials
    case credentialApprovalRequired
    case testing(id: UUID, snapshot: ServerFormModel.ConnectionSnapshot)
    case testSucceeded(snapshot: ServerFormModel.ConnectionSnapshot)
    case testFailed(snapshot: ServerFormModel.ConnectionSnapshot, failure: ServerConnectionTestFailure)
    case saving(id: UUID)
    case failed(message: String)
    case requiresUpgrade
}

@MainActor
final class ServerFormOperationController: ObservableObject {
    @Published private(set) var phase: ServerFormOperationPhase = .idle

    private let connectionTester: any ServerConnectionTesting
    private let hostKeys: any ServerHostKeyRepository
    private let saveUseCase: ServerSaveUseCase
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private var connectionTestTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(
        connectionTester: any ServerConnectionTesting,
        hostKeys: any ServerHostKeyRepository,
        saveUseCase: ServerSaveUseCase,
        now: @escaping @Sendable () -> Date,
        makeID: @escaping @Sendable () -> UUID
    ) {
        self.connectionTester = connectionTester
        self.hostKeys = hostKeys
        self.saveUseCase = saveUseCase
        self.now = now
        self.makeID = makeID
    }

    deinit {
        connectionTestTask?.cancel()
        saveTask?.cancel()
    }

    var isLoadingCredentials: Bool {
        phase == .loadingCredentials
    }

    var isTestingConnection: Bool {
        if case .testing = phase { return true }
        return false
    }

    var isSaving: Bool {
        if case .saving = phase { return true }
        return false
    }

    var credentialApprovalRequired: Bool {
        phase == .credentialApprovalRequired
    }

    var requiresUpgrade: Bool {
        phase == .requiresUpgrade
    }

    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    var connectionTestFailure: ServerConnectionTestFailure? {
        if case .testFailed(_, let failure) = phase { return failure }
        return nil
    }

    var hostKeyChallenge: KnownHostsManager.Challenge? {
        connectionTestFailure?.hostKeyChallenge
    }

    func hasValidConnectionTest(for snapshot: ServerFormModel.ConnectionSnapshot) -> Bool {
        guard case .testSucceeded(let completedSnapshot) = phase else { return false }
        return completedSnapshot == snapshot
    }

    func beginCredentialLoad() {
        phase = .loadingCredentials
    }

    func finishCredentialLoad() {
        guard phase == .loadingCredentials else { return }
        phase = .idle
    }

    func requireCredentialApproval() {
        phase = .credentialApprovalRequired
    }

    func fail(_ message: String) {
        phase = .failed(message: message)
    }

    func clearPresentation() {
        switch phase {
        case .credentialApprovalRequired, .failed, .requiresUpgrade, .testFailed:
            phase = .idle
        default:
            break
        }
    }

    func resetConnectionTest() {
        connectionTestTask?.cancel()
        connectionTestTask = nil
        switch phase {
        case .testing, .testSucceeded, .testFailed:
            phase = .idle
        default:
            break
        }
    }

    func startConnectionTest(
        server: Server,
        credentials: ServerCredentials,
        snapshot: ServerFormModel.ConnectionSnapshot
    ) {
        connectionTestTask?.cancel()
        let operationID = makeID()
        phase = .testing(id: operationID, snapshot: snapshot)

        let tester = connectionTester
        connectionTestTask = Task { [weak self] in
            let result = await tester.test(server: server, credentials: credentials)
            guard !Task.isCancelled else { return }
            self?.completeConnectionTest(
                id: operationID,
                snapshot: snapshot,
                result: result
            )
        }
    }

    func rejectHostKeyChallenge() {
        guard let challenge = hostKeyChallenge else { return }
        hostKeys.reject(challenge)
        phase = .idle
    }

    @discardableResult
    func approveHostKeyChallenge() -> Bool {
        guard let challenge = hostKeyChallenge,
              let snapshot = currentTestSnapshot else { return false }
        guard hostKeys.approve(challenge, now: now()) else {
            phase = .testFailed(
                snapshot: snapshot,
                failure: ServerConnectionTestFailure(
                    reason: .hostKeyApprovalExpired,
                    requiresCloudflareOverrides: false,
                    hostKeyChallenge: nil
                )
            )
            return false
        }
        phase = .idle
        return true
    }

    func save(
        mutation: ServerMutation,
        credentials: ServerCredentials,
        hasProAccess: Bool,
        authorize: @escaping @MainActor () async -> Bool,
        onSaved: @escaping @MainActor (Server) -> Void
    ) {
        guard !isSaving else { return }
        saveTask?.cancel()
        let operationID = makeID()
        phase = .saving(id: operationID)
        let useCase = saveUseCase

        saveTask = Task { [weak self] in
            guard await authorize() else {
                guard self?.isCurrentSave(operationID) == true else { return }
                self?.saveTask = nil
                self?.phase = .idle
                return
            }
            do {
                let savedServer = try await useCase.execute(
                    mutation,
                    credentials: credentials,
                    hasProAccess: hasProAccess
                )
                guard !Task.isCancelled else { return }
                guard self?.isCurrentSave(operationID) == true else { return }
                self?.saveTask = nil
                self?.phase = .idle
                onSaved(savedServer)
            } catch let error as VVTermError {
                guard !Task.isCancelled else { return }
                guard self?.isCurrentSave(operationID) == true else { return }
                self?.saveTask = nil
                if case .proRequired = error {
                    self?.phase = .requiresUpgrade
                } else {
                    self?.phase = .failed(message: error.localizedDescription)
                }
            } catch {
                guard !Task.isCancelled else { return }
                guard self?.isCurrentSave(operationID) == true else { return }
                self?.saveTask = nil
                self?.phase = .failed(message: error.localizedDescription)
            }
        }
    }

    func cancel() {
        connectionTestTask?.cancel()
        connectionTestTask = nil
        saveTask?.cancel()
        saveTask = nil
        phase = .idle
    }

    private var currentTestSnapshot: ServerFormModel.ConnectionSnapshot? {
        switch phase {
        case .testing(_, let snapshot), .testSucceeded(let snapshot), .testFailed(let snapshot, _):
            return snapshot
        default:
            return nil
        }
    }

    private func completeConnectionTest(
        id: UUID,
        snapshot: ServerFormModel.ConnectionSnapshot,
        result: ServerConnectionTestResult
    ) {
        guard case .testing(let currentID, let currentSnapshot) = phase,
              currentID == id,
              currentSnapshot == snapshot else { return }
        connectionTestTask = nil
        switch result {
        case .success:
            phase = .testSucceeded(snapshot: snapshot)
        case .failure(let failure):
            phase = .testFailed(snapshot: snapshot, failure: failure)
        case .cancelled:
            phase = .idle
        }
    }

    private func isCurrentSave(_ id: UUID) -> Bool {
        guard case .saving(let currentID) = phase else { return false }
        return currentID == id
    }
}
