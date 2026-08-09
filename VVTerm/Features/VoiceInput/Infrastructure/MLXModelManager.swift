import Foundation
import Combine
import os.log

enum MLXModelKind: String, CaseIterable, Identifiable {
    case whisper
    case parakeetTDT

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .whisper:
            return String(localized: "MLX Whisper")
        case .parakeetTDT:
            return String(localized: "MLX Parakeet")
        }
    }

    nonisolated var folderName: String {
        switch self {
        case .whisper:
            return "whisper"
        case .parakeetTDT:
            return "parakeet-tdt"
        }
    }
}

nonisolated struct MLXDownloadOperationState: Equatable, Sendable {
    nonisolated enum Phase: Equatable, Sendable {
        case idle
        case resolving(operationID: UUID)
        case downloading(operationID: UUID, taskIdentifier: Int)
    }

    private(set) var phase: Phase = .idle

    mutating func start() -> UUID? {
        guard phase == .idle else { return nil }
        let operationID = UUID()
        phase = .resolving(operationID: operationID)
        return operationID
    }

    mutating func beginTask(operationID: UUID, taskIdentifier: Int) -> Bool {
        guard phase == .resolving(operationID: operationID) else { return false }
        phase = .downloading(operationID: operationID, taskIdentifier: taskIdentifier)
        return true
    }

    func accepts(taskIdentifier: Int) -> Bool {
        guard case .downloading(_, let activeTaskIdentifier) = phase else { return false }
        return activeTaskIdentifier == taskIdentifier
    }

    @discardableResult
    mutating func finishTask(taskIdentifier: Int) -> Bool {
        guard case .downloading(let operationID, let activeTaskIdentifier) = phase,
              activeTaskIdentifier == taskIdentifier else { return false }
        phase = .resolving(operationID: operationID)
        return true
    }

    @discardableResult
    mutating func finish(operationID: UUID) -> Bool {
        guard phase == .resolving(operationID: operationID) else { return false }
        phase = .idle
        return true
    }

    @discardableResult
    mutating func cancel(operationID: UUID) -> Bool {
        let activeOperationID: UUID
        switch phase {
        case .idle:
            return false
        case .resolving(let operationID), .downloading(let operationID, _):
            activeOperationID = operationID
        }
        guard activeOperationID == operationID else { return false }
        phase = .idle
        return true
    }

    func isActive(operationID: UUID) -> Bool {
        switch phase {
        case .idle:
            return false
        case .resolving(let activeOperationID), .downloading(let activeOperationID, _):
            return activeOperationID == operationID
        }
    }
}

@MainActor
final class MLXModelManager: NSObject, ObservableObject {
    struct DownloadProgress: Equatable {
        var fraction: Double
        var bytesDownloaded: Int64
        var totalBytes: Int64
        var estimatedSecondsRemaining: Int?
    }

    enum DownloadState: Equatable {
        case idle
        case downloading(DownloadProgress)
        case ready
        case failed(String)
    }

    @Published private(set) var state: DownloadState = .idle
    @Published private(set) var localStorageBytes: Int64 = 0
    @Published private(set) var totalStorageBytes: Int64 = 0
    @Published private(set) var repoSizeBytes: Int64?
    @Published var modelId: String {
        didSet {
            if let activeContext, activeContext.modelID != normalizedModelId {
                cancelActiveDownload()
            }
            refreshStatus()
        }
    }

    let kind: MLXModelKind

    private let logger = Logger.settings
    private var session: URLSession!
    private var operationState = MLXDownloadOperationState()
    private var activeContext: DownloadContext?
    private var activeFile: ActiveFileDownload?
    private var completedBytes: Int64 = 0
    private var currentFileBytes: Int64 = 0
    private var expectedTotalBytes: Int64 = 0
    private var downloadStartTime: Date?
    private var storageTask: Task<Void, Never>?
    private var storageOperationID: UUID?
    private var repoSizeTask: Task<Void, Never>?
    private var lastRepoSizeModelId: String?

    init(kind: MLXModelKind, modelId: String) {
        self.kind = kind
        self.modelId = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    private struct HFModelInfo: Decodable {
        let siblings: [HFSibling]
        let usedStorage: Int64?
    }

    private struct HFSibling: Decodable {
        let rfilename: String
    }

    private struct SafetensorsIndex: Decodable {
        let weightMap: [String: String]

        enum CodingKeys: String, CodingKey {
            case weightMap = "weight_map"
        }
    }

    struct DownloadItem {
        let url: URL
        let destination: URL
    }

    private struct DownloadContext {
        let modelID: String
        let directory: URL
    }

    private struct ActiveFileDownload {
        let task: URLSessionDownloadTask
        let item: DownloadItem
        let continuation: CheckedContinuation<URL, Error>
    }

    var modelDirectory: URL {
        Self.modelDirectory(for: kind, modelId: normalizedModelId)
    }

    nonisolated static var modelsRoot: URL {
        #if os(iOS)
        // On iOS, use the app's documents directory
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsDir
            .appendingPathComponent("vvterm", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        #else
        // On macOS App Store builds, keep models inside the sandbox container.
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupportDir
            .appendingPathComponent("VVTerm", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        #endif
    }

    var isModelAvailable: Bool {
        Self.isModelAvailable(kind: kind, modelId: normalizedModelId)
    }

    func refreshStatus() {
        if isModelAvailable {
            state = .ready
        } else if case .downloading = state {
            return
        } else {
            state = .idle
        }
        refreshStorageUsage()
        refreshRepoSize()
    }

    func removeModel() {
        cancelActiveDownload()
        do {
            if FileManager.default.fileExists(atPath: modelDirectory.path) {
                try FileManager.default.removeItem(at: modelDirectory)
            }
            state = .idle
            refreshStorageUsage()
        } catch {
            logger.error("Failed to remove MLX model: \(error.localizedDescription)")
            state = .failed(String(localized: "Failed to remove model"))
        }
    }

    static func clearAllStorage() {
        let root = modelsRoot
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try? FileManager.default.removeItem(at: root)
    }

    func downloadModel() async {
        let modelId = normalizedModelId
        guard !modelId.isEmpty else {
            state = .failed(String(localized: "Model ID is required"))
            return
        }
        guard let operationID = operationState.start() else { return }

        let context = DownloadContext(
            modelID: modelId,
            directory: Self.modelDirectory(for: kind, modelId: modelId)
        )
        activeContext = context
        completedBytes = 0
        currentFileBytes = 0
        expectedTotalBytes = repoSizeBytes ?? 0
        downloadStartTime = Date()
        state = .downloading(DownloadProgress(
            fraction: 0,
            bytesDownloaded: 0,
            totalBytes: expectedTotalBytes,
            estimatedSecondsRemaining: nil
        ))

        do {
            try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: true)

            let items = try await resolveDownloadItems(context: context)
            guard operationState.isActive(operationID: operationID) else { return }

            for item in items {
                currentFileBytes = 0
                try await download(item, operationID: operationID)
                completedBytes = Self.addingBytes(completedBytes, currentFileBytes)
            }

            guard operationState.finish(operationID: operationID) else { return }
            activeContext = nil
            state = .ready
            refreshStorageUsage()
        } catch {
            guard operationState.finish(operationID: operationID) else { return }
            activeContext = nil
            logger.error("Failed to download MLX model: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    static func isModelAvailable(kind: MLXModelKind, modelId: String) -> Bool {
        let normalized = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let directory = modelDirectory(for: kind, modelId: normalized)
        let config = directory.appendingPathComponent("config.json")
        let weights = weightFiles(in: directory, allowedExtensions: allowedWeightExtensions(for: kind))
        return FileManager.default.fileExists(atPath: config.path) && !weights.isEmpty
    }

    nonisolated static func modelDirectory(for kind: MLXModelKind, modelId: String) -> URL {
        let sanitized = sanitizeModelId(modelId)
        return modelsRoot
            .appendingPathComponent(kind.folderName, isDirectory: true)
            .appendingPathComponent(sanitized, isDirectory: true)
    }

    nonisolated static func weightFiles(in directory: URL, allowedExtensions: Set<String>) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
    }

    static func allowedWeightExtensions(for kind: MLXModelKind) -> Set<String> {
        return Set(["safetensors", "npz"])
    }

    private var normalizedModelId: String {
        modelId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func sanitizeModelId(_ modelId: String) -> String {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.isEmpty ? "unknown-model" : trimmed
        return collapsed.replacingOccurrences(of: "/", with: "--")
    }

    nonisolated private static func directorySizeBytes(_ directory: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total = addingBytes(total, Int64(size))
        }
        return total
    }

    func refreshStorageUsage() {
        storageTask?.cancel()
        let operationID = UUID()
        storageOperationID = operationID
        let modelDir = modelDirectory
        let rootDir = Self.modelsRoot
        storageTask = Task.detached { [weak self] in
            let modelBytes = Self.directorySizeBytes(modelDir)
            let rootBytes = Self.directorySizeBytes(rootDir)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.storageOperationID == operationID,
                      self.modelDirectory == modelDir else { return }
                self.localStorageBytes = modelBytes
                self.totalStorageBytes = rootBytes
            }
        }
    }

    func refreshRepoSize() {
        let modelId = normalizedModelId
        guard !modelId.isEmpty else {
            repoSizeBytes = nil
            return
        }
        if lastRepoSizeModelId == modelId, repoSizeBytes != nil {
            return
        }
        repoSizeTask?.cancel()
        lastRepoSizeModelId = modelId
        repoSizeBytes = nil
        repoSizeTask = Task.detached { [weak self] in
            let size = await MLXModelSizeCache.shared.size(for: modelId)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.lastRepoSizeModelId == modelId,
                      self.normalizedModelId == modelId else { return }
                self.repoSizeBytes = size
            }
        }
    }

    private func resolveDownloadItems(context: DownloadContext) async throws -> [DownloadItem] {
        let base = "https://huggingface.co/\(context.modelID)/resolve/main"
        var configPath: String?
        var weightPaths: [String] = []
        let allowedExtensions = Self.allowedWeightExtensions(for: kind)

        if let files = try? await fetchModelFiles(modelID: context.modelID) {
            configPath = files.first { $0.hasSuffix("config.json") }

            if let indexPath = files.first(where: { $0.hasSuffix(".safetensors.index.json") }) {
                let indexURL = URL(string: "\(base)/\(indexPath)")!
                let (data, _) = try await session.data(from: indexURL)
                let index = try JSONDecoder().decode(SafetensorsIndex.self, from: data)
                weightPaths = Array(Set(index.weightMap.values)).sorted()
            }

            if weightPaths.isEmpty {
                if let safetensors = files.first(where: { $0.hasSuffix(".safetensors") }) {
                    weightPaths = [safetensors]
                } else if let npz = files.first(where: { $0.hasSuffix(".npz") }) {
                    weightPaths = [npz]
                }
            }
        }

        if configPath == nil {
            configPath = "config.json"
        }

        if weightPaths.isEmpty {
            if let indexed = try await resolveWeightsFromIndex(base: base) {
                weightPaths = indexed
            }
        }

        if !weightPaths.isEmpty {
            weightPaths = weightPaths.filter { path in
                allowedExtensions.contains((path as NSString).pathExtension.lowercased())
            }
            let hasSafetensors = weightPaths.contains { ($0 as NSString).pathExtension.lowercased() == "safetensors" }
            if hasSafetensors {
                weightPaths = weightPaths.filter { ($0 as NSString).pathExtension.lowercased() == "safetensors" }
            }
        }

        if weightPaths.isEmpty {
            weightPaths = try await resolveWeightsFallback(base: base, allowedExtensions: allowedExtensions)
        }

        guard !weightPaths.isEmpty else {
            throw NSError(domain: "MLXModelManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "No compatible weights found for this model"])
        }

        let configURL = URL(string: "\(base)/\(configPath!)")!
        var items: [DownloadItem] = [
            DownloadItem(url: configURL, destination: context.directory.appendingPathComponent("config.json"))
        ]

        for path in weightPaths {
            let url = URL(string: "\(base)/\(path)")!
            items.append(DownloadItem(url: url, destination: context.directory.appendingPathComponent((path as NSString).lastPathComponent)))
        }

        if kind == .whisper {
            let tokenizerBase = "https://raw.githubusercontent.com/openai/whisper/main/whisper/assets"
            let tokenizerFiles = ["gpt2.tiktoken", "multilingual.tiktoken"]
            for name in tokenizerFiles {
                if let url = URL(string: "\(tokenizerBase)/\(name)") {
                    items.append(DownloadItem(url: url, destination: context.directory.appendingPathComponent(name)))
                }
            }
        }

        return items
    }

    private func fetchModelFiles(modelID: String) async throws -> [String] {
        let url = URL(string: "https://huggingface.co/api/models/\(modelID)")!
        let (data, _) = try await session.data(from: url)
        let info = try JSONDecoder().decode(HFModelInfo.self, from: data)
        return info.siblings.map(\.rfilename)
    }

    private func resolveWeightsFallback(base: String, allowedExtensions: Set<String>) async throws -> [String] {
        let candidates = ["model.safetensors", "weights.safetensors", "weights.npz", "model.npz"]
        for name in candidates {
            let ext = (name as NSString).pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { continue }
            let url = URL(string: "\(base)/\(name)")!
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            do {
                let response = try await session.data(for: request).1
                if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                    return [name]
                }
            } catch {
                continue
            }
        }
        return []
    }

    private func resolveWeightsFromIndex(base: String) async throws -> [String]? {
        let indexNames = ["model.safetensors.index.json", "weights.safetensors.index.json"]
        for name in indexNames {
            let url = URL(string: "\(base)/\(name)")!
            do {
                let (data, _) = try await session.data(from: url)
                let index = try JSONDecoder().decode(SafetensorsIndex.self, from: data)
                let weights = Array(Set(index.weightMap.values)).sorted()
                if !weights.isEmpty {
                    return weights
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func download(_ item: DownloadItem, operationID: UUID) async throws {
        let task = session.downloadTask(with: item.url)

        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            guard operationState.beginTask(
                operationID: operationID,
                taskIdentifier: task.taskIdentifier
            ) else {
                continuation.resume(throwing: CancellationError())
                return
            }
            activeFile = ActiveFileDownload(task: task, item: item, continuation: continuation)
            task.resume()
        }
    }

    private func cancelActiveDownload() {
        guard let context = activeContext else { return }
        let operationID: UUID
        switch operationState.phase {
        case .idle:
            activeContext = nil
            return
        case .resolving(let id), .downloading(let id, _):
            operationID = id
        }

        guard operationState.cancel(operationID: operationID) else { return }
        activeContext = nil
        if let activeFile {
            self.activeFile = nil
            activeFile.continuation.resume(throwing: CancellationError())
            activeFile.task.cancel()
        }
        logger.info("Cancelled MLX model download for \(context.modelID)")
    }

    private func completeActiveFile(
        taskIdentifier: Int,
        result: Result<URL, Error>
    ) {
        guard operationState.accepts(taskIdentifier: taskIdentifier),
              let activeFile,
              activeFile.task.taskIdentifier == taskIdentifier else { return }

        self.activeFile = nil
        operationState.finishTask(taskIdentifier: taskIdentifier)
        activeFile.continuation.resume(with: result)
    }

    nonisolated static func addingBytes(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    private func updateProgress(currentBytes: Int64, currentTotalBytes: Int64) {
        currentFileBytes = currentBytes
        let totalDownloaded = Self.addingBytes(completedBytes, currentBytes)

        let fraction: Double
        let totalBytes: Int64
        if expectedTotalBytes > 0 {
            fraction = Double(totalDownloaded) / Double(expectedTotalBytes)
            totalBytes = expectedTotalBytes
        } else if currentTotalBytes > 0 {
            fraction = Double(currentBytes) / Double(currentTotalBytes)
            totalBytes = currentTotalBytes
        } else {
            fraction = 0
            totalBytes = 0
        }

        var eta: Int?
        if let startTime = downloadStartTime, totalDownloaded > 0 {
            let elapsed = Date().timeIntervalSince(startTime)
            let bytesPerSecond = Double(totalDownloaded) / elapsed
            if bytesPerSecond > 0 {
                let remainingBytes = max(totalBytes - min(totalDownloaded, totalBytes), 0)
                let seconds = Double(remainingBytes) / bytesPerSecond
                if seconds.isFinite {
                    eta = seconds >= Double(Int.max) ? Int.max : Int(seconds)
                }
            }
        }

        state = .downloading(DownloadProgress(
            fraction: min(max(fraction, 0), 1),
            bytesDownloaded: totalDownloaded,
            totalBytes: totalBytes,
            estimatedSecondsRemaining: eta
        ))
    }
}

extension MLXModelManager: @preconcurrency URLSessionDownloadDelegate {
    @MainActor
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard operationState.accepts(taskIdentifier: downloadTask.taskIdentifier),
              let activeFile,
              activeFile.task.taskIdentifier == downloadTask.taskIdentifier else { return }
        let item = activeFile.item
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            let status = response.statusCode
            completeActiveFile(taskIdentifier: downloadTask.taskIdentifier, result: .failure(NSError(
                domain: "MLXModelManager",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "Download failed with status \(status)"]
            )))
            return
        }
        do {
            if FileManager.default.fileExists(atPath: item.destination.path) {
                try FileManager.default.removeItem(at: item.destination)
            }
            try FileManager.default.moveItem(at: location, to: item.destination)
            completeActiveFile(taskIdentifier: downloadTask.taskIdentifier, result: .success(item.destination))
        } catch {
            completeActiveFile(taskIdentifier: downloadTask.taskIdentifier, result: .failure(error))
        }
    }

    @MainActor
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard operationState.accepts(taskIdentifier: downloadTask.taskIdentifier) else { return }
        updateProgress(currentBytes: totalBytesWritten, currentTotalBytes: totalBytesExpectedToWrite)
    }

    @MainActor
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        completeActiveFile(taskIdentifier: task.taskIdentifier, result: .failure(error))
    }
}
