import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension AnalyticsTracker: EngagementAnalytics {}

extension EngagementTrackerDependencies {
    static var live: Self {
        EngagementTrackerDependencies(
            persistence: UserDefaultsEngagementPersistence(defaults: .standard),
            analytics: AnalyticsTracker.shared,
            now: Date.init,
            startOfDay: { Calendar.current.startOfDay(for: $0) },
            applicationIsActive: {
                #if os(iOS)
                UIApplication.shared.applicationState == .active
                #elseif os(macOS)
                NSApplication.shared.isActive
                #else
                true
                #endif
            }
        )
    }
}
