import Foundation
import Combine
import os.log

// MARK: - Server Stats Collector

nonisolated struct ServerStatsCollectionState: Equatable, Sendable {
    enum Phase: Equatable {
        case idle
        case starting(attemptID: UUID)
        case collecting(attemptID: UUID)
        case failed(message: String)

        var attemptID: UUID? {
            switch self {
            case .starting(let attemptID), .collecting(let attemptID):
                return attemptID
            case .idle, .failed:
                return nil
            }
        }
    }

    private(set) var phase: Phase = .idle

    var isCollecting: Bool { phase.attemptID != nil }

    var errorMessage: String? {
        guard case .failed(let message) = phase else { return nil }
        return message
    }

    mutating func start(attemptID: UUID) {
        phase = .starting(attemptID: attemptID)
    }

    @discardableResult
    mutating func markConnected(attemptID: UUID) -> Bool {
        guard phase == .starting(attemptID: attemptID) else { return false }
        phase = .collecting(attemptID: attemptID)
        return true
    }

    @discardableResult
    mutating func finish(attemptID: UUID, errorMessage: String? = nil) -> Bool {
        guard phase.attemptID == attemptID else { return false }
        if let errorMessage {
            phase = .failed(message: errorMessage)
        } else {
            phase = .idle
        }
        return true
    }

    mutating func stop() {
        phase = .idle
    }
}

/// Main stats collector that uses a shared SSH connection when available
@MainActor
final class ServerStatsCollector: ObservableObject {
    @Published var stats = ServerStats()
    @Published var cpuHistory: [StatsPoint] = []
    @Published var memoryHistory: [StatsPoint] = []
    @Published var networkRxHistory: [StatsPoint] = []
    @Published var networkTxHistory: [StatsPoint] = []
    @Published var gpuUtilizationHistoryByDeviceID: [String: [StatsPoint]] = [:]
    @Published var dockerCPUHistory: [StatsPoint] = []
    @Published var dockerMemoryHistory: [StatsPoint] = []
    @Published private(set) var collectionState = ServerStatsCollectionState()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "Stats")
    private let dockerCollector = DockerStatsCollector()

    private final class CollectionAttempt {
        let id: UUID
        let client: SSHClient
        let ownsClient: Bool
        let context = StatsCollectionContext()
        var collectDocker: Bool
        var task: Task<Void, Never>?
        var remotePlatform: RemotePlatform = .unknown
        var platformCollector: PlatformStatsCollector?

        init(id: UUID, client: SSHClient, ownsClient: Bool, collectDocker: Bool) {
            self.id = id
            self.client = client
            self.ownsClient = ownsClient
            self.collectDocker = collectDocker
        }
    }

    private var activeAttempt: CollectionAttempt?

    var isCollecting: Bool { collectionState.isCollecting }
    var connectionError: String? { collectionState.errorMessage }

    // MARK: - Collection Control

    func startCollecting(
        for server: Server,
        using sharedClient: SSHClient? = nil,
        collectDocker: Bool = false
    ) async {
        if let activeAttempt {
            activeAttempt.collectDocker = collectDocker
            return
        }

        let client = sharedClient ?? SSHClient()
        let attempt = CollectionAttempt(
            id: UUID(),
            client: client,
            ownsClient: sharedClient == nil,
            collectDocker: collectDocker
        )
        activeAttempt = attempt
        collectionState.start(attemptID: attempt.id)
        resetCollectionState()

        // Get credentials
        let credentials: ServerCredentials
        do {
            credentials = try KeychainManager.shared.getCredentials(for: server)
        } catch {
            finishCollection(attemptID: attempt.id, withError: "No credentials found")
            return
        }

        // Connect in background
        let attemptID = attempt.id
        let ownsClient = attempt.ownsClient
        let task = Task.detached(priority: .utility) { [weak self] in
            var failureMessage: String?
            do {
                try await SSHConnectionOperationService.shared.runWithConnection(
                    using: client,
                    server: server,
                    credentials: credentials,
                    disconnectWhenDone: ownsClient
                ) { connectedClient in
                    guard await self?.markCollectionConnected(attemptID: attemptID) == true else { return }

                    while !Task.isCancelled {
                        let shouldContinue = await self?.isCurrentCollectionAttempt(attemptID) == true
                        guard shouldContinue else { break }

                        await self?.collectStats(attemptID: attemptID, client: connectedClient)
                        try await Task.sleep(for: .seconds(2))
                    }
                }
            } catch is CancellationError {
                // A stopped or superseded attempt must not publish an error.
            } catch {
                failureMessage = error.localizedDescription
            }

            await self?.finishCollection(attemptID: attemptID, withError: failureMessage)
        }
        attempt.task = task
    }

    func stopCollecting() {
        guard let attempt = activeAttempt else {
            collectionState.stop()
            return
        }

        activeAttempt = nil
        collectionState.stop()
        attempt.task?.cancel()
        attempt.task = nil

        // Disconnect SSH only if we own the connection
        if attempt.ownsClient {
            let client = attempt.client
            Task.detached {
                await client.disconnect()
            }
        }
    }

    func terminateProcess(_ process: ProcessInfo) async throws {
        guard process.pid > 1 else {
            throw ProcessControlError.protectedProcess
        }

        guard let attempt = activeAttempt else {
            throw ProcessControlError.notConnected
        }

        let command: String
        switch attempt.remotePlatform {
        case .windows:
            command = "taskkill /PID \(process.pid) /T /F"
        case .linux, .darwin, .freebsd, .openbsd, .netbsd, .unknown:
            command = "kill -TERM \(process.pid)"
        }

        _ = try await attempt.client.execute(command, timeout: .seconds(5))
        await collectStats(attemptID: attempt.id, client: attempt.client)
    }

    func loadProcesses() async throws -> [ProcessInfo] {
        guard let attempt = activeAttempt else {
            throw ProcessControlError.notConnected
        }
        guard let platformCollector = attempt.platformCollector else {
            return stats.topProcesses
        }

        let processes = try await platformCollector.collectProcesses(
            client: attempt.client,
            context: attempt.context
        )
        guard isCurrentCollectionAttempt(attempt.id) else {
            throw ProcessControlError.notConnected
        }
        return processes.isEmpty ? stats.topProcesses : processes
    }

    func loadDockerStats() async throws -> DockerStats {
        guard let attempt = activeAttempt else {
            throw ProcessControlError.notConnected
        }
        let dockerStats = await dockerCollector.collect(
            client: attempt.client,
            platform: attempt.remotePlatform,
            limit: nil,
            fallback: stats.docker
        )
        guard isCurrentCollectionAttempt(attempt.id) else {
            throw ProcessControlError.notConnected
        }
        attempt.context.updateDockerStats(dockerStats, timestamp: dockerStats.timestamp)
        stats.docker = dockerStats
        return dockerStats
    }

    /// Loads storage health only when the user opens a volume's detail view.
    /// The selected volume must still belong to the latest Stats snapshot so a
    /// stale sheet cannot probe an unrelated raw locator after a mount changes.
    func loadStorageHealth(for volume: VolumeInfo) async throws -> StorageHealthResult {
        guard let attempt = activeAttempt else {
            throw ProcessControlError.notConnected
        }
        guard let currentVolume = VolumeVisibilityPolicy.normalized(stats.volumes)
            .first(where: { $0.identity == volume.identity }) else {
            return .unavailable(.unmapped)
        }

        let platform: RemotePlatform
        let collector: PlatformStatsCollector
        if attempt.remotePlatform == .unknown {
            platform = await attempt.client.remotePlatform()
            guard isCurrentCollectionAttempt(attempt.id) else {
                throw ProcessControlError.notConnected
            }
            guard platform != .unknown else { return .unavailable(.unsupported) }
            let detectedCollector = platform.createCollector()
            attempt.remotePlatform = platform
            attempt.platformCollector = detectedCollector
            collector = detectedCollector
        } else {
            platform = attempt.remotePlatform
            guard let platformCollector = attempt.platformCollector else {
                return .unavailable(.unsupported)
            }
            collector = platformCollector
        }

        let resolution = try await StorageHealthTargetResolver.resolve(
            client: attempt.client,
            platform: platform,
            volume: currentVolume
        )
        switch resolution {
        case .topology(let topology):
            var members: [StorageHealthMemberReport] = []
            members.reserveCapacity(topology.members.count)
            for (ordinal, member) in topology.members.enumerated() {
                try Task.checkCancellation()
                let result: StorageDeviceHealthResult
                let memberFindings: [StorageHealthFinding]
                switch member {
                case .target(_, let target, let topologyFindings):
                    result = try await collector.collectStorageHealth(client: attempt.client, target: target)
                    memberFindings = topologyFindings
                case .unresolved(_, _, let reason):
                    result = .unavailable(reason)
                    memberFindings = []
                }
                members.append(StorageHealthMemberReport(
                    id: member.id,
                    role: member.role,
                    ordinal: ordinal + 1,
                    result: result,
                    findings: memberFindings
                ))
            }
            if topology.kind == .physicalDevice,
               members.count == 1,
               case .unavailable(let reason) = members[0].result {
                return .unavailable(reason)
            }

            let hasUnavailableMember = members.contains { member in
                if case .unavailable = member.result { return true }
                return false
            }
            let coverage: StorageHealthCoverage = topology.coverage == .partial || hasUnavailableMember
                ? .partial
                : .complete
            var findings = topology.findings
            if coverage == .partial,
               !findings.contains(where: { $0.kind == .partialCoverage }) {
                findings.append(StorageHealthFinding(
                    kind: .partialCoverage,
                    severity: .information,
                    source: topology.kind == .zfs ? .zfs : .btrfs
                ))
            }
            return .report(StorageHealthVolumeReport(
                topology: topology.kind,
                name: topology.name,
                coverage: coverage,
                findings: findings,
                members: members
            ))
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }

    func performDockerAction(_ action: DockerContainerAction, on container: DockerContainer) async throws -> DockerStats {
        guard let attempt = activeAttempt else {
            throw ProcessControlError.notConnected
        }

        try await dockerCollector.perform(
            action,
            container: container,
            client: attempt.client,
            platform: attempt.remotePlatform
        )
        try? await Task.sleep(for: .milliseconds(500))
        let dockerStats = await dockerCollector.collect(
            client: attempt.client,
            platform: attempt.remotePlatform,
            limit: nil,
            fallback: stats.docker
        )
        guard isCurrentCollectionAttempt(attempt.id) else {
            throw ProcessControlError.notConnected
        }
        attempt.context.updateDockerStats(dockerStats, timestamp: dockerStats.timestamp)
        stats.docker = dockerStats
        return dockerStats
    }

    // MARK: - Stats Collection

    private func collectStats(attemptID: UUID, client: SSHClient) async {
        guard let attempt = currentCollectionAttempt(attemptID) else { return }

        do {
            // Detect platform and create collector on first run
            if attempt.remotePlatform == .unknown {
                let remotePlatform = await client.remotePlatform()
                guard let attempt = currentCollectionAttempt(attemptID) else { return }
                attempt.remotePlatform = remotePlatform
                attempt.platformCollector = remotePlatform.createCollector()

                logger.info("Detected remote platform: \(remotePlatform.rawValue)")

                // Get initial hardware profile. Individual platform collectors return
                // partial profiles when optional probes are unavailable.
                let profile = await collectInitialProfile(attempt: attempt)
                guard currentCollectionAttempt(attemptID) != nil else { return }
                applyProfile(profile)
            }

            // Collect stats using platform-specific collector
            guard let currentAttempt = currentCollectionAttempt(attemptID),
                  let collector = currentAttempt.platformCollector else { return }

            var newStats = try await collector.collectStats(client: client, context: currentAttempt.context)
            guard let currentAttempt = currentCollectionAttempt(attemptID) else { return }

            // Preserve system info
            let existingStats = stats
            let collectedCpuCores = newStats.cpuCores
            newStats.hostname = existingStats.hostname
            newStats.osInfo = existingStats.osInfo
            newStats.cpuCores = Self.resolvedCPUCoreCount(
                existing: existingStats.cpuCores,
                collected: collectedCpuCores
            )
            newStats.hardware = existingStats.hardware
            if newStats.gpuSamples.isEmpty, !existingStats.gpuSamples.isEmpty {
                newStats.gpuSamples = existingStats.gpuSamples
            }
            if currentAttempt.collectDocker {
                newStats.docker = await collectDockerStatsIfNeeded(
                    attempt: currentAttempt,
                    timestamp: newStats.timestamp
                )
            }

            guard currentCollectionAttempt(attemptID) != nil else { return }
            applyCollectedStats(newStats)

        } catch {
            guard currentCollectionAttempt(attemptID) != nil else { return }
            logger.error("Failed to collect stats: \(error.localizedDescription)")
            finishCollection(attemptID: attemptID, withError: error.localizedDescription)
        }
    }

    private func resetCollectionState() {
        cpuHistory = []
        memoryHistory = []
        networkRxHistory = []
        networkTxHistory = []
        gpuUtilizationHistoryByDeviceID = [:]
        dockerCPUHistory = []
        dockerMemoryHistory = []
    }

    private func collectInitialProfile(attempt: CollectionAttempt) async -> HardwareProfile? {
        guard let platformCollector = attempt.platformCollector else { return nil }

        if let profile = try? await platformCollector.collectProfile(client: attempt.client) {
            return profile
        }

        if let systemInfo = try? await platformCollector.getSystemInfo(client: attempt.client) {
            return HardwareProfile(
                hostname: systemInfo.hostname,
                osInfo: systemInfo.osInfo,
                architecture: "",
                kernelVersion: "",
                cpuModel: "",
                cpuVendor: "",
                cpuCores: systemInfo.cpuCores,
                cpuThreads: systemInfo.cpuCores,
                memoryTotal: 0,
                gpus: [],
                collectedAt: Date()
            )
        }

        return nil
    }

    private func currentCollectionAttempt(_ attemptID: UUID) -> CollectionAttempt? {
        guard activeAttempt?.id == attemptID else { return nil }
        return activeAttempt
    }

    private func isCurrentCollectionAttempt(_ attemptID: UUID) -> Bool {
        activeAttempt?.id == attemptID
    }

    private func markCollectionConnected(attemptID: UUID) -> Bool {
        guard currentCollectionAttempt(attemptID) != nil else { return false }
        return collectionState.markConnected(attemptID: attemptID)
    }

    private func finishCollection(attemptID: UUID, withError error: String? = nil) {
        guard currentCollectionAttempt(attemptID) != nil,
              collectionState.finish(attemptID: attemptID, errorMessage: error) else { return }
        activeAttempt = nil
    }

    private func applyProfile(_ profile: HardwareProfile?) {
        let hardwareProfile = profile ?? .empty
        stats.hardware = hardwareProfile
        stats.hostname = hardwareProfile.hostname
        stats.osInfo = hardwareProfile.osInfo
        let profileCPUCount = hardwareProfile.cpuThreads > 0 ? hardwareProfile.cpuThreads : hardwareProfile.cpuCores
        if profileCPUCount > 0 {
            stats.cpuCores = profileCPUCount
        }
        if stats.memoryTotal == 0 {
            stats.memoryTotal = hardwareProfile.memoryTotal
        }
    }

    private func applyCollectedStats(_ newStats: ServerStats) {
        stats = newStats

        cpuHistory.append(StatsPoint(timestamp: newStats.timestamp, value: newStats.cpuUsage))
        memoryHistory.append(StatsPoint(timestamp: newStats.timestamp, value: newStats.memoryPercent))
        networkRxHistory.append(StatsPoint(timestamp: newStats.timestamp, value: Double(newStats.networkRxSpeed)))
        networkTxHistory.append(StatsPoint(timestamp: newStats.timestamp, value: Double(newStats.networkTxSpeed)))
        dockerCPUHistory.append(StatsPoint(timestamp: newStats.timestamp, value: newStats.docker.aggregateCPUPercent))
        dockerMemoryHistory.append(StatsPoint(timestamp: newStats.timestamp, value: newStats.docker.memoryPercent))
        appendGPUHistory(from: newStats)

        if cpuHistory.count > 60 { cpuHistory.removeFirst() }
        if memoryHistory.count > 60 { memoryHistory.removeFirst() }
        if networkRxHistory.count > 60 { networkRxHistory.removeFirst() }
        if networkTxHistory.count > 60 { networkTxHistory.removeFirst() }
        if dockerCPUHistory.count > 60 { dockerCPUHistory.removeFirst() }
        if dockerMemoryHistory.count > 60 { dockerMemoryHistory.removeFirst() }
    }

    private func collectDockerStatsIfNeeded(
        attempt: CollectionAttempt,
        timestamp: Date
    ) async -> DockerStats {
        guard attempt.context.shouldCollectDocker(now: timestamp) else {
            return attempt.context.getDockerStats()
        }

        let dockerStats = await dockerCollector.collect(
            client: attempt.client,
            platform: attempt.remotePlatform,
            limit: DockerStatsCollector.periodicContainerLimit,
            fallback: attempt.context.getDockerStats()
        )
        attempt.context.updateDockerStats(dockerStats, timestamp: timestamp)
        return dockerStats
    }

    private func appendGPUHistory(from newStats: ServerStats) {
        for sample in newStats.gpuSamples {
            guard let utilization = sample.utilizationPercent else { continue }
            var history = gpuUtilizationHistoryByDeviceID[sample.deviceID] ?? []
            history.append(StatsPoint(timestamp: newStats.timestamp, value: utilization))
            if history.count > 60 {
                history.removeFirst(history.count - 60)
            }
            gpuUtilizationHistoryByDeviceID[sample.deviceID] = history
        }
    }

    nonisolated static func resolvedCPUCoreCount(existing: Int, collected: Int) -> Int {
        if existing > 0, collected > 0 {
            return max(existing, collected)
        }
        if existing > 0 {
            return existing
        }
        return max(collected, 0)
    }
}

private enum ProcessControlError: LocalizedError {
    case notConnected
    case protectedProcess

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Stats is not connected to the server.")
        case .protectedProcess:
            return String(localized: "This process cannot be killed from Stats.")
        }
    }
}
