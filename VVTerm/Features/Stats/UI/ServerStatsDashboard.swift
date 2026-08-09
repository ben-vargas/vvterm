import SwiftUI

struct ServerStatsDashboard: View {
    let server: Server
    let isVisible: Bool
    let backgroundColor: Color
    var sharedClientProvider: () -> SSHClient?
    @ObservedObject var statsCollector: ServerStatsCollector
    let preferences: StatsPreferences
    @ObservedObject var volumeVisibilityStore: ServerVolumeVisibilityStore
    let securityApprovalActions: ServerStatsSecurityApprovalActions
    let isDockerUnlocked: Bool
    let showAppearanceSettings: () -> Void
    let showDockerUpgrade: () -> Void
    @State private var approvalRequestInFlight: ServerSecurityApprovalRequest?

    var body: some View {
        let style = StatsVisualStyle(preferencesStyle: preferences.style)
        let storageVolumes = VolumeVisibilityPolicy.normalized(statsCollector.stats.volumes)
        let hiddenStorageVolumeIDs = volumeVisibilityStore.hiddenVolumeIDs(
            for: server.id,
            volumes: storageVolumes
        )

        ZStack {
            ScrollView {
                StatsBlocksContent(
                    serverName: server.name,
                    stats: statsCollector.stats,
                    cpuHistory: statsCollector.cpuHistory,
                    memoryHistory: statsCollector.memoryHistory,
                    gpuHistories: statsCollector.gpuUtilizationHistoryByDeviceID,
                    networkRxHistory: statsCollector.networkRxHistory,
                    networkTxHistory: statsCollector.networkTxHistory,
                    dockerCPUHistory: statsCollector.dockerCPUHistory,
                    dockerMemoryHistory: statsCollector.dockerMemoryHistory,
                    preferences: preferences,
                    storageVolumes: storageVolumes,
                    hiddenStorageVolumeIDs: hiddenStorageVolumeIDs,
                    backgroundColor: backgroundColor,
                    surface: .dashboard,
                    constrainsWidth: true,
                    usesPagePadding: true,
                    isDockerUnlocked: isDockerUnlocked,
                    showsCustomizationEntryPoint: true,
                    customizeAction: showAppearanceSettings,
                    dockerUpgradeAction: showDockerUpgrade,
                    terminateProcess: { process in
                        try await statsCollector.terminateProcess(process)
                    },
                    loadProcesses: {
                        try await statsCollector.loadProcesses()
                    },
                    loadDockerStats: {
                        try await statsCollector.loadDockerStats()
                    },
                    performDockerAction: { action, container in
                        try await statsCollector.performDockerAction(action, on: container)
                    },
                    loadStorageHealth: { volume in
                        try await statsCollector.loadStorageHealth(for: volume)
                    },
                    setStorageVolumeVisibility: { volume, isVisible in
                        volumeVisibilityStore.setVolume(volume, isVisible: isVisible, for: server.id)
                    },
                    setStorageVolumesVisibility: { volumes, areVisible in
                        volumeVisibilityStore.setVolumes(volumes, areVisible: areVisible, for: server.id)
                    }
                )
            }

            if isVisible, let error = statsCollector.connectionError {
                ConnectionErrorOverlay(error: error, style: style) {
                    Task {
                        await statsCollector.startCollecting(
                            for: server,
                            using: sharedClientProvider(),
                            collectDocker: isDockerUnlocked
                        )
                    }
                }
                .padding()
            }
        }
        .task(id: makeTaskKey()) {
            if isVisible {
                await statsCollector.startCollecting(
                    for: server,
                    using: sharedClientProvider(),
                    collectDocker: isDockerUnlocked
                )
            } else {
                statsCollector.stopCollecting()
            }
        }
        .task(id: approvalRequestInFlight?.id) {
            await performSecurityApprovalIfNeeded()
        }
        .onDisappear {
            approvalRequestInFlight = nil
            statsCollector.stopCollecting()
        }
        .alert(
            credentialApprovalPresentation.title,
            isPresented: credentialApprovalBinding
        ) {
            Button("Cancel", role: .cancel) {
                cancelCredentialApproval()
            }
            Button(credentialApprovalPresentation.approvalButtonTitle) {
                beginCredentialApproval()
            }
        } message: {
            Text(credentialApprovalPresentation.message)
        }
        .alert(
            hostKeyPresentation?.title ?? String(localized: "Trust SSH Host?"),
            isPresented: hostKeyApprovalBinding
        ) {
            Button("Cancel", role: .cancel) {
                cancelHostKeyApproval()
            }
            if hostKeyPresentation?.isDestructive == false {
                Button(hostKeyPresentation?.approvalButtonTitle ?? String(localized: "Trust and Reconnect")) {
                    beginHostKeyApproval()
                }
            } else {
                Button(
                    hostKeyPresentation?.approvalButtonTitle ?? String(localized: "Replace and Reconnect"),
                    role: .destructive
                ) {
                    beginHostKeyApproval()
                }
            }
        } message: {
            Text(hostKeyPresentation?.message ?? "")
        }
    }

    private var credentialApprovalPresentation: ServerCredentialApprovalPresentation {
        ServerCredentialApprovalPresentation(server: server)
    }

    private var credentialApprovalBinding: Binding<Bool> {
        Binding(
            get: {
                guard case .credentialEndpoint(let serverID) = statsCollector.securityApproval else {
                    return false
                }
                return serverID == server.id
            },
            set: { _ in }
        )
    }

    private var hostKeyRequest: ServerSecurityApprovalRequest? {
        guard let request = statsCollector.securityApproval,
              case .hostKey = request else {
            return nil
        }
        return request
    }

    private var hostKeyPresentation: SSHHostKeyTrustPresentation? {
        guard let hostKeyRequest,
              case .hostKey(let challenge) = hostKeyRequest else { return nil }
        return SSHHostKeyTrustPresentation(challenge: challenge)
    }

    private var hostKeyApprovalBinding: Binding<Bool> {
        Binding(
            get: { hostKeyRequest != nil },
            set: { _ in }
        )
    }

    private func cancelCredentialApproval() {
        guard let request = statsCollector.securityApproval,
              case .credentialEndpoint = request else { return }
        approvalRequestInFlight = nil
        securityApprovalActions.reject(request)
        statsCollector.resolveSecurityApproval(request, error: .cancelled)
    }

    private func beginCredentialApproval() {
        guard let request = statsCollector.securityApproval,
              case .credentialEndpoint(let serverID) = request,
              serverID == server.id else { return }
        approvalRequestInFlight = request
    }

    private func cancelHostKeyApproval() {
        guard let request = statsCollector.securityApproval,
              case .hostKey = request else { return }
        approvalRequestInFlight = nil
        securityApprovalActions.reject(request)
        statsCollector.resolveSecurityApproval(request, error: .cancelled)
    }

    private func beginHostKeyApproval() {
        guard let request = statsCollector.securityApproval,
              case .hostKey = request else { return }
        approvalRequestInFlight = request
    }

    private func performSecurityApprovalIfNeeded() async {
        guard let request = approvalRequestInFlight else { return }
        let outcome = await securityApprovalActions.approve(request, server)

        guard !Task.isCancelled else { return }
        guard approvalRequestInFlight == request,
              statsCollector.securityApproval == request else {
            if approvalRequestInFlight == request {
                approvalRequestInFlight = nil
            }
            return
        }

        switch outcome {
        case .approved:
            statsCollector.resolveSecurityApproval(request)
            await retryCollection()
            guard !Task.isCancelled, approvalRequestInFlight == request else { return }
        case .failed(let error):
            statsCollector.resolveSecurityApproval(request, error: error)
        }
        approvalRequestInFlight = nil
    }

    private func retryCollection() async {
        await statsCollector.startCollecting(
            for: server,
            using: sharedClientProvider(),
            collectDocker: isDockerUnlocked
        )
    }

    private func makeTaskKey() -> String {
        let clientId = sharedClientProvider().map { ObjectIdentifier($0).hashValue } ?? 0
        return "\(server.id.uuidString)-\(isVisible)-\(clientId)-\(isDockerUnlocked)"
    }
}
