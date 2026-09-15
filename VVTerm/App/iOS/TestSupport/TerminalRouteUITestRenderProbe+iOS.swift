#if os(iOS) && DEBUG
import Foundation

/// Counts route evaluation without publishing state or changing view identity.
@MainActor
enum TerminalRouteUITestRenderProbe {
    private(set) static var updateCount = 0

    static func recordUpdate() {
        guard Foundation.ProcessInfo.processInfo.arguments.contains("--vvterm-ui-test-repeat-keyboard-state") else { return }
        updateCount += 1
    }
}
#endif
