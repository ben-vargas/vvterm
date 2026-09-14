#if DEBUG
import SwiftUI

struct CustomThemeDuplicateUITestHarness: View {
    @StateObject private var manager: TerminalThemeManager

    init() {
        let ports = CustomThemeUITestPorts()
        _manager = StateObject(wrappedValue: TerminalThemeManager(dependencies: .init(
            persistence: ports, cloud: ports, mutationQueue: ports,
            syncLifecycle: ports, preferenceChanges: ports, themeFiles: ports,
            builtInThemeCatalog: ports, paletteResolver: ports,
            isSyncEnabled: { false }, now: Date.init,
            waitForPreferenceSyncDebounce: {}, startsSynchronization: false
        )))
    }

    var body: some View {
        NavigationStack {
            ManageCustomThemesSheet(
                customThemes: manager.customThemes.filter { !$0.isDeleted },
                themeSelection: manager.themeSelection,
                onClose: {},
                onSuggestThemeName: { manager.suggestThemeName(from: $0) },
                onCreateTheme: { name, content, target in
                    let theme = try manager.createCustomTheme(name: name, content: content)
                    manager.selectTheme(named: theme.name, for: target)
                },
                onApplyTheme: { manager.selectTheme(named: $0, for: $1) },
                onDuplicate: { try manager.duplicateCustomTheme(id: $0) },
                onDelete: { manager.deleteCustomTheme(id: $0) },
                onSaveEdit: { try manager.updateCustomTheme(id: $0, name: $1, content: $2) }
            )
        }
    }
}

/// In-memory ports keep this UI test away from user themes, files, and CloudKit.
@MainActor
private final class CustomThemeUITestPorts: TerminalThemePersistence, TerminalThemeCloudClient,
    TerminalThemeMutationQueue, TerminalThemeSyncLifecycle, TerminalThemePreferenceChangeSource,
    TerminalThemeFileSynchronizing, BuiltInTerminalThemeCatalog, TerminalThemePaletteResolving {
    private var themes = [
        TerminalTheme(id: UUID(uuidString: "00000000-0000-0000-0000-000000000235")!, name: "Original", content: "background = #123456\nforeground = #abcdef\n"),
        TerminalTheme(id: UUID(uuidString: "00000000-0000-0000-0000-000000000236")!, name: "Broken", content: "not a theme")
    ]
    private var selection = TerminalThemeSelection(darkThemeName: "Original", lightThemeName: "Original", usePerAppearanceTheme: false)
    private var updatedAt = Date.distantPast

    func loadCustomThemes() throws -> [TerminalTheme] { themes }
    func saveCustomThemes(_ themes: [TerminalTheme]) throws { self.themes = themes }
    func loadSelection() -> TerminalThemeSelection { selection }
    func saveSelection(_ selection: TerminalThemeSelection) { self.selection = selection }
    func loadPreferenceUpdatedAt() -> Date { updatedAt }
    func savePreferenceUpdatedAt(_ date: Date) { updatedAt = date }
    func cacheActiveBackgroundHex(_ hex: String) {}
    func fetchTerminalThemes() async throws -> [TerminalTheme] { [] }
    func fetchTerminalThemePreference() async throws -> TerminalThemePreference? { nil }
    func enqueueTerminalThemeUpsert(_ theme: TerminalTheme) throws {}
    func enqueueTerminalThemePreferenceUpsert(_ preference: TerminalThemePreference) throws {}
    func drainPendingMutations() async {}
    func observe(_ observer: @escaping (CloudKitSyncLifecycleEvent) -> Void) -> UUID { UUID() }
    func removeObserver(_ id: UUID) {}
    func observeChanges(_ observer: @escaping @MainActor @Sendable () -> Void) -> NSObjectProtocol { NSObject() }
    func removeObserver(_ observer: NSObjectProtocol) {}
    func synchronize(_ themes: [TerminalTheme]) throws {}
    func themeNames() -> [String] { ["Aizen Dark", "Aizen Light"] }
    func palette(forThemeNamed name: String) -> TerminalThemePalette { .fallback }
    func palette(forThemeContent content: String) -> TerminalThemePalette { .fallback }
    func invalidateCache() {}
}
#endif
