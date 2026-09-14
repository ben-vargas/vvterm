import Combine
import Foundation

@MainActor
final class TerminalComposerStore: ObservableObject {
    enum Operation: Equatable {
        case idle
        case loading
        case uploading(String)
        case failed(String)
    }

    @Published private(set) var mode = TerminalInputMode.direct
    @Published var draft = ""
    @Published private(set) var attachments: [TerminalAttachmentPayload] = []
    @Published private(set) var operation = Operation.idle
    @Published var pickerPresented = false

    private let resolveRoute: @MainActor () async throws -> TerminalAttachmentRoute
    private let modeChanged: @MainActor (TerminalInputMode) -> Void
    private var task: Task<Void, Never>?
    private var taskID: UUID?

    init(resolveRoute: @escaping @MainActor () async throws -> TerminalAttachmentRoute,
         modeChanged: @escaping @MainActor (TerminalInputMode) -> Void = { _ in }) {
        self.resolveRoute = resolveRoute
        self.modeChanged = modeChanged
    }

    var isBusy: Bool {
        switch operation {
        case .loading, .uploading: true
        case .idle, .failed: false
        }
    }

    var canSend: Bool { !isBusy && ((mode == .chat && !draft.isEmpty) || !attachments.isEmpty) }

    func setMode(_ mode: TerminalInputMode) {
        guard self.mode != mode else { return }
        cancel()
        if mode == .direct { attachments.removeAll() }
        pickerPresented = false
        self.mode = mode
        modeChanged(mode)
    }

    func removeAttachment(_ id: UUID) {
        guard !isBusy else { return }
        attachments.removeAll { $0.id == id }
        operation = .idle
    }

    func add(_ payloads: [TerminalAttachmentPayload]) throws {
        guard !isBusy else { return }
        try TerminalAttachmentLimits.validate(attachments + payloads)
        attachments.append(contentsOf: payloads)
        operation = .idle
    }

    func load(_ loader: @escaping @Sendable () async throws -> [TerminalAttachmentPayload]) {
        guard !isBusy else { return }
        let id = UUID()
        taskID = id
        operation = .loading
        task = Task { [weak self] in
            do {
                let payloads = try await loader()
                try Task.checkCancellation()
                guard let self, self.taskID == id else { return }
                self.operation = .idle
                try self.add(payloads)
                self.task = nil
                self.taskID = nil
                if self.mode == .direct { self.send() }
            } catch {
                guard let self, self.taskID == id else { return }
                self.operation = .failed(error.localizedDescription)
                self.task = nil
                self.taskID = nil
            }
        }
    }

    func send() {
        guard canSend else { return }
        let inputMode = mode
        let text = inputMode == .chat ? draft : ""
        let payloads = attachments
        let id = UUID()
        taskID = id
        operation = .uploading(payloads.first?.suggestedFilename ?? "")
        let resolveRoute = resolveRoute
        task = Task { [weak self] in
            var route: TerminalAttachmentRoute?
            var uploads: [RemoteClipboardUpload] = []
            var filename: String?
            do {
                let resolved = try await resolveRoute()
                route = resolved
                try Task.checkCancellation()
                for payload in payloads {
                    try Task.checkCancellation()
                    filename = payload.suggestedFilename
                    if self?.taskID == id { self?.operation = .uploading(payload.suggestedFilename) }
                    uploads.append(try await resolved.upload(payload))
                }
                try Task.checkCancellation()
                guard let self, self.taskID == id else { throw CancellationError() }
                try resolved.submit(Self.compose(text: text, pathTokens: uploads.map(\.pastedPathToken)), inputMode)
                if self.mode == .chat, self.draft == text { self.draft = "" }
                let sentIDs = Set(payloads.map(\.id))
                self.attachments.removeAll { sentIDs.contains($0.id) }
                self.operation = .idle
                self.task = nil
                self.taskID = nil
            } catch {
                if let route, !uploads.isEmpty {
                    // Cleanup must run even when the sending task was cancelled.
                    await Task { await route.remove(uploads) }.value
                }
                guard let self, self.taskID == id else { return }
                self.operation = error is CancellationError ? .idle : .failed(
                    filename.map { "\($0): \(error.localizedDescription)" } ?? error.localizedDescription
                )
                self.task = nil
                self.taskID = nil
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        taskID = nil
        operation = .idle
    }

    func discardAttachments() {
        cancel()
        attachments.removeAll()
    }

    func tearDown() {
        discardAttachments()
        draft = ""
        pickerPresented = false
    }

    nonisolated static func compose(text: String, pathTokens: [String]) -> String {
        ([text].filter { !$0.isEmpty } + pathTokens).joined(separator: " ")
    }

    deinit { task?.cancel() }
}
