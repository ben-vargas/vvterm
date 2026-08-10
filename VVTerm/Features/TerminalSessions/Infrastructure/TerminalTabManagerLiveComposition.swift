import Combine
import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
enum TerminalTabManagerLiveComposition {
    private static let persistenceKey = "terminalTabsSnapshot.v1"

    static func makeManager(
        appLockManager: AppLockManager,
        serverManager: ServerManager,
        engagementTracker: EngagementTracker
    ) -> TerminalTabManager {
        let defaults = UserDefaults.standard
        let networkMonitor = NetworkMonitor.shared
        let eternalTerminalResumeStore = EternalTerminalResumeStore.shared
        let terminalSurfaceStore = GhosttyTerminalSurfaceStore()
        let tmuxCoordinator = TerminalTmuxSessionLiveComposition.makeCoordinator(
            defaults: defaults,
            serverManager: serverManager
        )
        let dependencies = TerminalTabManagerDependencies(
            networkReadiness: TerminalNetworkReadinessSource(
                initial: TerminalNetworkReadiness(networkMonitor.readiness),
                updates: networkMonitor.$snapshot
                    .map { TerminalNetworkReadiness($0.readiness) }
                    .removeDuplicates()
                    .eraseToAnyPublisher()
            ),
            applicationIsActive: {
                #if os(iOS)
                UIApplication.shared.applicationState == .active
                #else
                NSApplication.shared.isActive
                #endif
            },
            appLock: TerminalAppLockSource(
                initialIsLocked: appLockManager.isAppLocked,
                updates: appLockManager.$lockState
                    .map(\.isLocked)
                    .removeDuplicates()
                    .eraseToAnyPublisher()
            ),
            effects: TerminalSessionApplicationEffects(
                authorizeServer: { server in
                    await appLockManager.ensureServerUnlocked(server)
                },
                refreshLiveActivity: { connectionStates in
                    LiveActivityManager.shared.refresh(with: connectionStates)
                },
                recordSuccessfulConnection: { id, transport in
                    engagementTracker.recordSuccessfulConnection(
                        id: id,
                        transport: transport
                    )
                },
                noteTerminalSessionEnded: { otherTerminalsActive in
                    engagementTracker.noteTerminalSessionEnded(
                        otherTerminalsActive: otherTerminalsActive
                    )
                },
                recordSplitPaneCreated: {
                    AnalyticsTracker.shared.trackSplitPaneCreated()
                }
            ),
            remoteMosh: RemoteMoshManager.shared,
            eternalTerminalRuntime: .live(
                resumeStore: eternalTerminalResumeStore
            )
        )
        return TerminalTabManager(
            snapshotStore: UserDefaultsTerminalTabSnapshotStore(
                defaults: defaults,
                key: persistenceKey
            ),
            dependencies: dependencies,
            tmuxCoordinator: tmuxCoordinator,
            terminalSurfaceStore: terminalSurfaceStore,
            eternalTerminalResumeStore: eternalTerminalResumeStore,
            moshRecovery: TerminalMoshRecoveryService(
                store: MoshResumeStore.shared
            )
        )
    }
}

extension RemoteMoshManager: TerminalRemoteMoshServicing {}

private extension TerminalNetworkReadiness {
    init(_ readiness: NetworkMonitor.Readiness) {
        switch readiness {
        case .unknown:
            self = .unknown
        case .ready:
            self = .ready
        case .unavailable:
            self = .unavailable
        }
    }
}
