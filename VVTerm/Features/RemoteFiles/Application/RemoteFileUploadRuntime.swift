import Combine
import Foundation

/// Retains uploads for one file tab independently from its SwiftUI screen.
@MainActor
final class RemoteFileUploadRuntime: ObservableObject {
    enum Phase: Equatable {
        case running(
            message: String,
            completedUnitCount: Int?,
            totalUnitCount: Int?
        )
        case awaitingSecurityApproval(message: String)
        case succeeded(message: String)
        case failed(message: String)
    }

    struct Operation: Identifiable, Equatable {
        let id: UUID
        let title: String
        var phase: Phase
    }

    typealias ProgressHandler = @MainActor (RemoteFileBrowserStore.TransferProgress) -> Void
    typealias UploadOperation = (@escaping ProgressHandler) async throws -> Void

    private struct PendingApproval {
        let operationID: UUID
        let request: ServerSecurityApprovalRequest
        let retry: @MainActor () -> Void
    }

    @Published private(set) var operations: [Operation] = []
    @Published private var pendingApproval: PendingApproval?

    private let server: Server
    private var tasksByOperationID: [UUID: Task<Void, Never>] = [:]
    private var dismissalTasksByOperationID: [UUID: Task<Void, Never>] = [:]

    var securityApprovalRequest: ServerSecurityApprovalRequest? {
        pendingApproval?.request
    }

    init(server: Server) {
        self.server = server
    }

    @discardableResult
    func start(
        title: String,
        initialMessage: String,
        successMessage: String,
        operation: @escaping UploadOperation
    ) -> UUID {
        let operationID = UUID()
        setOperation(Operation(
            id: operationID,
            title: title,
            phase: .running(
                message: initialMessage,
                completedUnitCount: nil,
                totalUnitCount: nil
            )
        ))
        launch(
            operationID: operationID,
            title: title,
            successMessage: successMessage,
            allowsSecurityRetry: true,
            operation: operation
        )
        return operationID
    }

    func contains(_ operationID: UUID) -> Bool {
        operations.contains { $0.id == operationID }
    }

    func cancel(_ operationID: UUID) {
        tasksByOperationID.removeValue(forKey: operationID)?.cancel()
        dismissalTasksByOperationID.removeValue(forKey: operationID)?.cancel()
        if pendingApproval?.operationID == operationID {
            rejectPendingChallenge()
            clearPendingApproval()
        }
        removeOperation(operationID)
    }

    func dismiss(_ operationID: UUID) {
        guard tasksByOperationID[operationID] == nil else { return }
        dismissalTasksByOperationID.removeValue(forKey: operationID)?.cancel()
        removeOperation(operationID)
    }

    func approveSecurityRequest() {
        guard let pendingApproval else { return }
        switch pendingApproval.request {
        case .hostKey(let challenge):
            guard KnownHostsManager.shared.approve(challenge) else {
                fail(
                    operationID: pendingApproval.operationID,
                    message: ServerSecurityApprovalError.expired.localizedDescription
                )
                clearPendingApproval()
                return
            }
        }

        let retry = pendingApproval.retry
        clearPendingApproval()
        retry()
    }

    func cancelSecurityRequest() {
        guard let pendingApproval else { return }
        rejectPendingChallenge()
        fail(
            operationID: pendingApproval.operationID,
            message: ServerSecurityApprovalError.cancelled.localizedDescription
        )
        clearPendingApproval()
    }

    func cancelAll() {
        let tasks = Array(tasksByOperationID.values)
        let dismissalTasks = Array(dismissalTasksByOperationID.values)
        tasksByOperationID.removeAll(keepingCapacity: false)
        dismissalTasksByOperationID.removeAll(keepingCapacity: false)
        tasks.forEach { $0.cancel() }
        dismissalTasks.forEach { $0.cancel() }
        rejectPendingChallenge()
        clearPendingApproval()
        operations.removeAll(keepingCapacity: false)
    }

    private func launch(
        operationID: UUID,
        title: String,
        successMessage: String,
        allowsSecurityRetry: Bool,
        operation: @escaping UploadOperation
    ) {
        tasksByOperationID[operationID]?.cancel()
        tasksByOperationID[operationID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await operation { [weak self] progress in
                    self?.report(progress, for: operationID)
                }
                try Task.checkCancellation()
                self.tasksByOperationID[operationID] = nil
                self.setOperation(Operation(
                    id: operationID,
                    title: title,
                    phase: .succeeded(message: successMessage)
                ))
                self.scheduleDismissal(for: operationID)
            } catch is CancellationError {
                self.tasksByOperationID[operationID] = nil
                self.removeOperation(operationID)
            } catch {
                self.tasksByOperationID[operationID] = nil
                if allowsSecurityRetry,
                   self.beginSecurityApprovalIfNeeded(
                       for: error,
                       operationID: operationID,
                       retry: { [weak self] in
                           self?.launch(
                               operationID: operationID,
                               title: title,
                               successMessage: successMessage,
                               allowsSecurityRetry: false,
                               operation: operation
                           )
                       }
                   ) {
                    return
                }

                let mappedError = RemoteFileBrowserError.map(error)
                let message: String
                if !allowsSecurityRetry, mappedError == .hostKeyApprovalRequired {
                    message = ServerSecurityApprovalError.unavailable.localizedDescription
                } else {
                    message = mappedError.errorDescription ?? error.localizedDescription
                }
                self.fail(operationID: operationID, message: message)
            }
        }
    }

    private func report(
        _ progress: RemoteFileBrowserStore.TransferProgress,
        for operationID: UUID
    ) {
        guard let current = operations.first(where: { $0.id == operationID }) else { return }
        let itemName = progress.currentItemName.isEmpty
            ? String(localized: "item")
            : progress.currentItemName
        let message: String
        if progress.completedUnitCount == 0 {
            message = String(format: String(localized: "Uploading %@"), itemName)
        } else {
            message = String(
                format: String(localized: "%lld of %lld: %@"),
                Int64(progress.completedUnitCount),
                Int64(progress.totalUnitCount),
                itemName
            )
        }
        setOperation(Operation(
            id: operationID,
            title: current.title,
            phase: .running(
                message: message,
                completedUnitCount: progress.completedUnitCount,
                totalUnitCount: progress.totalUnitCount
            )
        ))
    }

    private func beginSecurityApprovalIfNeeded(
        for error: Error,
        operationID: UUID,
        retry: @escaping @MainActor () -> Void
    ) -> Bool {
        guard pendingApproval == nil else { return false }

        let request = ServerSecurityApprovalRequest.detect(error, server: server)
            ?? fallbackApprovalRequest(for: error)
        guard let request else { return false }

        pendingApproval = PendingApproval(
            operationID: operationID,
            request: request,
            retry: retry
        )
        if let current = operations.first(where: { $0.id == operationID }) {
            setOperation(Operation(
                id: operationID,
                title: current.title,
                phase: .awaitingSecurityApproval(
                    message: String(localized: "Approve the server identity to continue uploading.")
                )
            ))
        }
        return true
    }

    private func fallbackApprovalRequest(for error: Error) -> ServerSecurityApprovalRequest? {
        guard RemoteFileBrowserError.map(error) == .hostKeyApprovalRequired else { return nil }
        return KnownHostsManager.shared.pendingChallenge(
            for: server.host,
            port: server.port
        ).map(ServerSecurityApprovalRequest.hostKey)
    }

    private func fail(operationID: UUID, message: String) {
        guard let current = operations.first(where: { $0.id == operationID }) else { return }
        setOperation(Operation(
            id: operationID,
            title: current.title,
            phase: .failed(message: message)
        ))
    }

    private func setOperation(_ operation: Operation) {
        if let index = operations.firstIndex(where: { $0.id == operation.id }) {
            guard operations[index] != operation else { return }
            operations[index] = operation
        } else {
            operations.append(operation)
        }
    }

    private func removeOperation(_ operationID: UUID) {
        operations.removeAll { $0.id == operationID }
    }

    private func scheduleDismissal(for operationID: UUID) {
        dismissalTasksByOperationID[operationID]?.cancel()
        dismissalTasksByOperationID[operationID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.dismissalTasksByOperationID[operationID] = nil
            self?.removeOperation(operationID)
        }
    }

    private func rejectPendingChallenge() {
        guard let request = pendingApproval?.request else { return }
        if case .hostKey(let challenge) = request {
            KnownHostsManager.shared.reject(challenge)
        }
    }

    private func clearPendingApproval() {
        pendingApproval = nil
    }

    isolated deinit {
        tasksByOperationID.values.forEach { $0.cancel() }
        dismissalTasksByOperationID.values.forEach { $0.cancel() }
    }
}
