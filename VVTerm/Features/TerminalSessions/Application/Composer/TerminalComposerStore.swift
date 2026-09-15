import Combine
import Foundation
import OSLog

@MainActor
final class TerminalComposerStore: ObservableObject {
    enum Operation: Equatable {
        case idle
        case loading
        case uploading(id: UUID?, filename: String)
        case failed(String)
    }

    enum AttachmentSource: CaseIterable { case camera, photos, files, paste }

    @Published private(set) var mode = TerminalInputMode.direct
    @Published var draft = ""
    @Published private(set) var attachments: [TerminalAttachmentPayload] = []
    @Published private(set) var operation = Operation.idle
    @Published private(set) var cleanupError: String?
    @Published var attachmentSource: AttachmentSource?

    private let resolveRoute: @MainActor () async throws -> TerminalAttachmentRoute
    private let modeChanged: @MainActor (TerminalInputMode) -> Void
    private var task: Task<Void, Never>?
    private var taskID: UUID?
    private struct PreparedAttachments {
        let route: TerminalAttachmentRoute
        var uploads: [UUID: RemoteClipboardUpload] = [:]
    }
    private var prepared: PreparedAttachments?

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

    var canSend: Bool { !isBusy && (mode == .chat || !attachments.isEmpty) }

    func isUploading(_ attachment: TerminalAttachmentPayload) -> Bool {
        if case .uploading(let id, _) = operation { return id == attachment.id }
        return false
    }

    func setMode(_ mode: TerminalInputMode) {
        guard self.mode != mode else { return }
        cancel()
        if mode == .direct { attachments.removeAll() }
        attachmentSource = nil
        self.mode = mode
        modeChanged(mode)
    }

    func appendTranscription(_ text: String) {
        guard mode == .chat else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !draft.isEmpty, draft.last?.isWhitespace == false { draft += " " }
        draft += text
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
        if let upload = prepared?.uploads.removeValue(forKey: id), let route = prepared?.route {
            removeRemote([upload], using: route)
        }
        if !isBusy { operation = .idle }
    }

    func add(_ payloads: [TerminalAttachmentPayload]) throws {
        try TerminalAttachmentLimits.validate(attachments + payloads)
        guard !isBusy else { return }
        attachments.append(contentsOf: payloads)
        operation = .idle
        if mode == .chat { prepare(action: nil) }
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
                try TerminalAttachmentLimits.validate(self.attachments + payloads)
                self.attachments.append(contentsOf: payloads)
                self.task = nil
                self.taskID = nil
                self.prepare(action: self.mode == .direct ? .insert : nil)
            } catch {
                guard let self, self.taskID == id else { return }
                self.operation = .failed(error.localizedDescription)
                self.task = nil
                self.taskID = nil
            }
        }
    }

    func send(action: TerminalComposerSendAction = .send) {
        guard canSend, !action.steps.isEmpty else { return }
        prepare(action: mode == .direct ? .insert : action)
    }

    func dismissCleanupError() { cleanupError = nil }

    func cancel() {
        task?.cancel()
        task = nil
        taskID = nil
        discardPrepared()
        operation = .idle
    }

    func discardAttachments() {
        cancel()
        attachments.removeAll()
    }

    func tearDown() {
        discardAttachments()
        draft = ""
        attachmentSource = nil
    }

    nonisolated static func compose(text: String, pathTokens: [String]) -> String {
        ([text].filter { !$0.isEmpty } + pathTokens).joined(separator: " ")
    }

    private func prepare(action: TerminalComposerSendAction?) {
        let inputMode = mode
        let insertsDraft = action?.insertsDraft ?? true
        let text = inputMode == .chat && insertsDraft ? draft : ""
        let payloads = insertsDraft ? attachments : []
        let id = UUID()
        taskID = id
        operation = .uploading(id: payloads.first?.id, filename: payloads.first?.suggestedFilename ?? "")
        let resolveRoute = resolveRoute
        task = Task { [weak self] in
            var filename: String?
            do {
                if self?.prepared?.route.isCurrent() == false { self?.discardPrepared() }
                let route: TerminalAttachmentRoute
                if let existing = self?.prepared?.route { route = existing }
                else { route = try await resolveRoute() }
                try Task.checkCancellation()
                guard self?.taskID == id else { return }
                if self?.prepared == nil { self?.prepared = PreparedAttachments(route: route) }
                for payload in payloads {
                    try Task.checkCancellation()
                    guard self?.attachments.contains(where: { $0.id == payload.id }) == true,
                          self?.prepared?.uploads[payload.id] == nil else { continue }
                    filename = payload.suggestedFilename
                    self?.operation = .uploading(id: payload.id, filename: payload.suggestedFilename)
                    let upload = try await route.upload(payload)
                    // The picker may be dismissed or a file removed while an
                    // uncancellable transport operation is finishing.
                    guard !Task.isCancelled, self?.taskID == id,
                          self?.attachments.contains(where: { $0.id == payload.id }) == true else {
                        let removal = Self.removeRemote([upload], using: route) { [weak self] message in
                            self?.cleanupError = message
                        }
                        await removal.value
                        try Task.checkCancellation()
                        continue
                    }
                    self?.prepared?.uploads[payload.id] = upload
                }
                try Task.checkCancellation()
                guard let self, self.taskID == id else { return }
                guard route.isCurrent() else { throw TerminalAttachmentError.unavailable }
                if let action {
                    let sentPayloads = payloads.filter { payload in self.attachments.contains { $0.id == payload.id } }
                    let paths = try sentPayloads.map { payload in
                        guard let upload = self.prepared?.uploads[payload.id] else { throw TerminalAttachmentError.unavailable }
                        return upload.pastedPathToken
                    }
                    let composed = Self.compose(text: text, pathTokens: paths)
                    try route.submit(composed, action)
                    if insertsDraft, self.mode == .chat, self.draft == text { self.draft = "" }
                    let sentIDs = Set(sentPayloads.map(\.id))
                    self.attachments.removeAll { sentIDs.contains($0.id) }
                    // Only an action that inserts the draft transfers attachment ownership.
                    if insertsDraft { self.prepared = nil }
                }
                self.operation = .idle
                self.task = nil
                self.taskID = nil
            } catch {
                guard let self, self.taskID == id else { return }
                let cleanup = insertsDraft ? self.discardPrepared() : nil
                await cleanup?.value
                guard self.taskID == id else { return }
                // Normal Mode has no draft to retry. A later selection starts
                // a new batch and must not resend hidden, failed attachments.
                if inputMode == .direct { self.attachments.removeAll() }
                self.operation = error is CancellationError ? .idle : .failed(
                    filename.map { "\($0): \(error.localizedDescription)" } ?? error.localizedDescription
                )
                self.task = nil
                self.taskID = nil
            }
        }
    }

    @discardableResult
    private func discardPrepared() -> Task<Void, Never>? {
        guard let prepared else { return nil }
        self.prepared = nil
        let uploads = Array(prepared.uploads.values)
        guard !uploads.isEmpty else { return nil }
        // Remote cleanup must finish even after the draft owner is torn down.
        return removeRemote(uploads, using: prepared.route)
    }

    @discardableResult
    private func removeRemote(_ uploads: [RemoteClipboardUpload], using route: TerminalAttachmentRoute) -> Task<Void, Never> {
        Self.removeRemote(uploads, using: route) { [weak self] message in self?.cleanupError = message }
    }

    private static func removeRemote(
        _ uploads: [RemoteClipboardUpload], using route: TerminalAttachmentRoute,
        onFailure: @escaping @MainActor (String) -> Void
    ) -> Task<Void, Never> {
        Task {
            do { try await route.remove(uploads) }
            catch {
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "TerminalComposer")
                    .error("Remote attachment cleanup failed: \(LogPrivacy.errorClass(error), privacy: .public)")
                onFailure(error.localizedDescription)
            }
        }
    }

    isolated deinit {
        task?.cancel()
        discardPrepared()
    }
}
