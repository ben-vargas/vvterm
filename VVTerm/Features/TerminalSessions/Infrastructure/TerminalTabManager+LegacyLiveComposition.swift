import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
extension TerminalTabManager {
    /// DEV-228-only compatibility composition for Remote Files default initializers.
    /// App roots construct and inject their own manager instead.
    static let shared: TerminalTabManager = {
        let defaults = UserDefaults.standard
        let appLockManager = AppLockManager.shared
        let serverManager = ServerManager.shared
        let analyticsTracker = AnalyticsTracker.shared
        let remoteTmux = RemoteTmuxManager.shared
        let eternalTerminalResumeStore = EternalTerminalResumeStore.shared
        let applicationIsActive = {
            #if os(iOS)
            UIApplication.shared.applicationState == .active
            #else
            NSApplication.shared.isActive
            #endif
        }
        let engagementTracker = EngagementTracker(
            dependencies: .live(
                defaults: defaults,
                analytics: analyticsTracker,
                now: Date.init,
                calendar: .current,
                applicationIsActive: applicationIsActive
            )
        )

        return TerminalTabManagerLiveComposition.makeManager(
            defaults: defaults,
            networkMonitor: NetworkMonitor.shared,
            appLockManager: appLockManager,
            serverManager: serverManager,
            engagementTracker: engagementTracker,
            analyticsTracker: analyticsTracker,
            liveActivityManager: LiveActivityManager.shared,
            remoteMosh: RemoteMoshManager.shared,
            remoteTmux: remoteTmux,
            eternalTerminalResumeStore: eternalTerminalResumeStore,
            moshResumeStore: MoshResumeStore.shared,
            terminalSurfaceStore: GhosttyTerminalSurfaceStore(),
            deviceID: DeviceIdentity.id,
            themeStyle: {
                TerminalTmuxSessionLiveComposition.themeStyle(
                    for: defaults.string(
                        forKey: CloudKitSyncConstants.terminalThemeNameKey
                    )
                )
            },
            applicationIsActive: applicationIsActive
        )
    }()
}
