import SwiftUI

struct TerminalNotificationNavigationModifier: ViewModifier {
    @EnvironmentObject private var navigation: TerminalNotificationNavigationStore
    @EnvironmentObject private var appLock: AppLockManager
    @Environment(\.scenePhase) private var scenePhase
    let onOpen: (Server?) -> Void

    private var availableDestination: TerminalNotificationContext? {
        scenePhase == .active && !appLock.isAppLocked ? navigation.pending : nil
    }

    func body(content: Content) -> some View {
        content.task(id: availableDestination) {
            guard let context = availableDestination,
                  let destination = await navigation.resolve(context),
                  !Task.isCancelled, navigation.pending == context else { return }
            switch destination {
            case .app: onOpen(nil)
            case .terminal(let server): onOpen(server)
            }
            navigation.consume(context)
        }
    }
}
