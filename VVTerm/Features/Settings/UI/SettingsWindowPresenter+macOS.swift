#if os(macOS)
import AppKit
import SwiftUI

@MainActor
protocol SettingsWindowHandling: AnyObject {
    var isVisible: Bool { get }
    func presentSettingsWindow()
}

extension NSWindow: SettingsWindowHandling {
    func presentSettingsWindow() {
        makeKeyAndOrderFront(nil)
    }
}

/// Owns the macOS settings window and reuses it while it remains visible.
@MainActor
final class SettingsWindowPresenter {
    typealias MakeWindow = @MainActor () -> any SettingsWindowHandling

    private let makeWindow: MakeWindow
    private var settingsWindow: (any SettingsWindowHandling)?

    init(
        appLockManager: AppLockManager,
        terminalThemeManager: TerminalThemeManager,
        terminalAccessoryPreferencesManager: TerminalAccessoryPreferencesManager,
        storeManager: StoreManager
    ) {
        makeWindow = {
            let settingsView = LocalizedSettingsView(
                appLockManager: appLockManager,
                terminalThemeManager: terminalThemeManager,
                terminalAccessoryPreferencesManager: terminalAccessoryPreferencesManager,
                storeManager: storeManager
            )
            return Self.makeSettingsWindow(rootView: settingsView)
        }
    }

    init(makeWindow: @escaping MakeWindow) {
        self.makeWindow = makeWindow
    }

    func show() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.presentSettingsWindow()
            return
        }

        let window = makeWindow()
        window.presentSettingsWindow()
        settingsWindow = window
    }

    private static func makeSettingsWindow<Content: View>(
        rootView: Content
    ) -> NSWindow {
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.setContentSize(NSSize(width: 800, height: 600))
        window.minSize = NSSize(width: 750, height: 500)
        window.center()
        return window
    }
}

/// Observes language changes and injects the app-owned settings dependencies.
private struct LocalizedSettingsView: View {
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
    @ObservedObject var appLockManager: AppLockManager
    @ObservedObject var terminalThemeManager: TerminalThemeManager
    @ObservedObject var terminalAccessoryPreferencesManager: TerminalAccessoryPreferencesManager
    @ObservedObject var storeManager: StoreManager

    var body: some View {
        let locale = AppLanguage(rawValue: appLanguage)?.locale ?? Locale.current
        AppLockContainer {
            SettingsView()
                .modifier(AppearanceModifier())
                .adaptiveSoftScrollEdges()
                .environment(\.locale, locale)
                .environmentObject(terminalThemeManager)
                .environmentObject(terminalAccessoryPreferencesManager)
                .environmentObject(storeManager)
        }
        .environmentObject(appLockManager)
    }
}
#endif
