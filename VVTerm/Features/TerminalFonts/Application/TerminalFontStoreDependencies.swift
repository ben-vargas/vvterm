import Foundation

@MainActor
protocol TerminalFontCloudClient: AnyObject {
    func fetchTerminalFonts() async throws -> [TerminalFont]
    func fetchTerminalFontPreference() async throws -> TerminalFontPreference?
}

@MainActor
protocol TerminalFontCloudMutationClient: AnyObject {
    func saveTerminalFont(_ font: TerminalFont) async throws
    func saveTerminalFontPreference(_ preference: TerminalFontPreference) async throws
}

@MainActor
protocol TerminalFontMutationQueue: AnyObject {
    func enqueueTerminalFontUpsert(_ font: TerminalFont) throws
    func enqueueTerminalFontPreferenceUpsert(_ preference: TerminalFontPreference) throws
    func drainPendingMutations() async
}

@MainActor
protocol TerminalFontSyncLifecycle: AnyObject {
    func observe(_ observer: @escaping (CloudKitSyncLifecycleEvent) -> Void) -> UUID
    func removeObserver(_ id: UUID)
}

@MainActor
struct TerminalFontStoreDependencies {
    let repository: any TerminalFontRepository
    let cloud: any TerminalFontCloudClient
    let mutationQueue: any TerminalFontMutationQueue
    let syncLifecycle: any TerminalFontSyncLifecycle
    let loadCatalog: ([TerminalFontFamily]) -> TerminalFontCatalog
    let isSyncEnabled: () -> Bool
    let now: () -> Date
    let startsSynchronization: Bool
}
