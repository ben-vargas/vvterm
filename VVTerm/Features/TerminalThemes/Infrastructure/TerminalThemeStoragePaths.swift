import Foundation

nonisolated enum TerminalThemeStoragePaths {
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

    nonisolated static func customThemeFileURL(for themeName: String) -> URL? {
        guard let name = try? TerminalThemeValidator.validateAndNormalizeThemeName(themeName) else {
            return nil
        }
        let directoryURL = customThemesDirectoryURL().standardizedFileURL.resolvingSymlinksInPath()
        let fileURL = directoryURL
            .appendingPathComponent(name, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard fileURL.deletingLastPathComponent() == directoryURL else { return nil }
        return fileURL
    }

    nonisolated static func customThemeFilePath(for themeName: String) -> String? {
        customThemeFileURL(for: themeName)?.path
    }
}
