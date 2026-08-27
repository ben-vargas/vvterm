import Foundation

extension CloudKitSyncCoordinator: TerminalFontMutationQueue {
    func enqueueTerminalFontUpsert(_ font: TerminalFont) throws {
        try enqueue(.terminalFontUpsert(font))
    }

    func enqueueTerminalFontPreferenceUpsert(_ preference: TerminalFontPreference) throws {
        try enqueue(.terminalFontPreferenceUpsert(preference))
    }
}

extension CloudKitSyncLifecycleDriver: TerminalFontSyncLifecycle {}

extension TerminalFontStoreDependencies {
    static func live(
        repository: any TerminalFontRepository,
        cloud: any TerminalFontCloudClient,
        mutationQueue: any TerminalFontMutationQueue,
        syncLifecycle: any TerminalFontSyncLifecycle,
        isSyncEnabled: @escaping () -> Bool,
        now: @escaping () -> Date
    ) -> Self {
        TerminalFontStoreDependencies(
            repository: repository,
            cloud: cloud,
            mutationQueue: mutationQueue,
            syncLifecycle: syncLifecycle,
            loadCatalog: { customFamilies in
                TerminalFontCatalog.live(appOwnedFamilies: customFamilies)
            },
            isSyncEnabled: isSyncEnabled,
            now: now,
            startsSynchronization: true
        )
    }
}
