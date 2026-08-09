import SwiftUI

struct ServerStatsDashboard: View {
    @EnvironmentObject private var appLockManager: AppLockManager

    let server: Server
    let isVisible: Bool
    let backgroundColor: Color
    var sharedClientProvider: () -> SSHClient?
    @ObservedObject var statsCollector: ServerStatsCollector
    let preferences: StatsPreferences
    @ObservedObject var volumeVisibilityStore: ServerVolumeVisibilityStore
    let isDockerUnlocked: Bool
    let showAppearanceSettings: () -> Void
    let showDockerUpgrade: () -> Void

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
        .onDisappear {
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
                approveCredentialEndpointAndRetry()
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
                    approveHostKeyAndRetry()
                }
            } else {
                Button(
                    hostKeyPresentation?.approvalButtonTitle ?? String(localized: "Replace and Reconnect"),
                    role: .destructive
                ) {
                    approveHostKeyAndRetry()
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

    private var hostKeyChallenge: KnownHostsManager.Challenge? {
        guard case .hostKey(let challenge) = statsCollector.securityApproval else {
            return nil
        }
        return challenge
    }

    private var hostKeyPresentation: SSHHostKeyTrustPresentation? {
        hostKeyChallenge.map(SSHHostKeyTrustPresentation.init)
    }

    private var hostKeyApprovalBinding: Binding<Bool> {
        Binding(
            get: { hostKeyChallenge != nil },
            set: { _ in }
        )
    }

    private func cancelCredentialApproval() {
        guard let request = statsCollector.securityApproval,
              case .credentialEndpoint = request else { return }
        statsCollector.resolveSecurityApproval(request, error: .cancelled)
    }

    private func approveCredentialEndpointAndRetry() {
        guard let request = statsCollector.securityApproval,
              case .credentialEndpoint(let serverID) = request,
              serverID == server.id else { return }

        Task {
            guard await appLockManager.authorizeProtectedServerAction(
                server,
                action: .approveCredentialEndpoint
            ) else {
                statsCollector.resolveSecurityApproval(request, error: .cancelled)
                return
            }

            do {
                try KeychainManager.shared.approveCredentialUse(for: server)
                statsCollector.resolveSecurityApproval(request)
                await retryCollection()
            } catch {
                statsCollector.resolveSecurityApproval(request, error: .unavailable)
            }
        }
    }

    private func cancelHostKeyApproval() {
        guard let request = statsCollector.securityApproval,
              case .hostKey(let challenge) = request else { return }
        KnownHostsManager.shared.reject(challenge)
        statsCollector.resolveSecurityApproval(request, error: .cancelled)
    }

    private func approveHostKeyAndRetry() {
        guard let request = statsCollector.securityApproval,
              case .hostKey(let challenge) = request else { return }
        guard KnownHostsManager.shared.approve(challenge) else {
            statsCollector.resolveSecurityApproval(request, error: .expired)
            return
        }
        statsCollector.resolveSecurityApproval(request)
        Task { await retryCollection() }
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
