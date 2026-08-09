import Combine
import Foundation

#if os(iOS)
import UIKit
#endif

@MainActor
enum TerminalTabManagerLiveComposition {
    private static let persistenceKey = "terminalTabsSnapshot.v1"

    static func makeManager() -> TerminalTabManager {
        let defaults = UserDefaults.standard
        let networkMonitor = NetworkMonitor.shared
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
                true
                #endif
            },
            effects: TerminalSessionApplicationEffects(
                authorizeServer: { server in
                    await AppLockManager.shared.ensureServerUnlocked(server)
                },
                refreshLiveActivity: { connectionStates in
                    LiveActivityManager.shared.refresh(with: connectionStates)
                },
                recordSuccessfulConnection: { id, transport in
                    EngagementTracker.shared.recordSuccessfulConnection(
                        id: id,
                        transport: transport
                    )
                },
                noteTerminalSessionEnded: { otherTerminalsActive in
                    EngagementTracker.shared.noteTerminalSessionEnded(
                        otherTerminalsActive: otherTerminalsActive
                    )
                },
                recordSplitPaneCreated: {
                    AnalyticsTracker.shared.trackSplitPaneCreated()
                }
            ),
            tmuxConfiguration: TerminalTmuxConfiguration(
                deviceID: DeviceIdentity.id,
                enabledByDefault: {
                    guard defaults.object(forKey: "terminalTmuxEnabledDefault") != nil else {
                        return true
                    }
                    return defaults.bool(forKey: "terminalTmuxEnabledDefault")
                },
                startupBehaviorByDefault: {
                    guard let rawValue = defaults.string(
                        forKey: "terminalTmuxStartupBehaviorDefault"
                    ) else {
                        return .askEveryTime
                    }
                    return TmuxStartupBehavior(rawValue: rawValue) ?? .askEveryTime
                },
                serverSettings: { serverId in
                    ServerManager.shared.servers
                        .first(where: { $0.id == serverId })
                        .map {
                            TerminalTmuxConfiguration.ServerSettings(
                                name: $0.name,
                                enabledOverride: $0.tmuxEnabledOverride,
                                startupBehaviorOverride: $0.tmuxStartupBehaviorOverride
                            )
                        }
                },
                themeStyle: {
                    TerminalTabManager.remoteTmuxThemeStyle(
                        for: defaults.string(
                            forKey: CloudKitSyncConstants.terminalThemeNameKey
                        )
                    )
                }
            ),
            remoteTmux: RemoteTmuxManager.shared,
            remoteMosh: RemoteMoshManager.shared,
            eternalTerminalRuntime: .live
        )
        return TerminalTabManager(
            snapshotStore: UserDefaultsTerminalTabSnapshotStore(
                defaults: defaults,
                key: persistenceKey
            ),
            dependencies: dependencies,
            eternalTerminalResumeStore: EternalTerminalResumeStore.shared,
            moshResumeStore: MoshResumeStore.shared
        )
    }
}

extension RemoteTmuxManager: TerminalRemoteTmuxServicing {}
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
