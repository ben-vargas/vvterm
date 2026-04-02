import Foundation

enum TerminalThemeStoragePaths {
    nonisolated static func customThemesDirectoryURL() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let bundleComponent = Bundle.main.bundleIdentifier ?? "app.vivy.vvterm"
        return appSupport
            .appendingPathComponent(bundleComponent, isDirectory: true)
            .appendingPathComponent("CustomThemes", isDirectory: true)
    }

    nonisolated static func customThemesDirectoryPath() -> String {
        customThemesDirectoryURL().path
    }

    nonisolated static func customThemeFilePath(for themeName: String) -> String {
        customThemesDirectoryURL().appendingPathComponent(themeName).path
    }
}
