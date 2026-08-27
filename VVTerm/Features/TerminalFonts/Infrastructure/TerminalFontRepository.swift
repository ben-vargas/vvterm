import CoreText
import CryptoKit
import Foundation

@MainActor
protocol TerminalFontAssetRepository: AnyObject {
    func installRemoteAsset(from sourceURL: URL, for font: TerminalFont) throws
    func existingFileURL(for font: TerminalFont) -> URL?
}

@MainActor
protocol TerminalFontRepository: TerminalFontAssetRepository {
    func loadFonts() throws -> [TerminalFont]
    func saveFonts(_ fonts: [TerminalFont]) throws
    func loadPreference() -> TerminalFontPreference
    func savePreference(_ preference: TerminalFontPreference)
    func importFont(from sourceURL: URL, now: Date) throws -> TerminalFont
    func registerAvailableFonts(
        _ fonts: [TerminalFont]
    ) -> [TerminalFont.ID: [TerminalFontFamily]]
    func removeFile(for font: TerminalFont)
}

@MainActor
final class LocalTerminalFontRepository: TerminalFontRepository {
    private let rootDirectoryURL: URL
    private let fileManager: FileManager
    private let defaults: UserDefaults

    init(
        rootDirectoryURL: URL,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        self.rootDirectoryURL = rootDirectoryURL
        self.fileManager = fileManager
        self.defaults = defaults
    }

    static func applicationSupport(
        defaults: UserDefaults = .standard
    ) -> LocalTerminalFontRepository {
        LocalTerminalFontRepository(
            rootDirectoryURL: TerminalFontFilePaths.customFontsDirectoryURL(),
            defaults: defaults
        )
    }

    func loadFonts() throws -> [TerminalFont] {
        guard let data = defaults.data(forKey: StorageKey.fonts) else { return [] }
        return try JSONDecoder().decode([TerminalFont].self, from: data)
    }

    func saveFonts(_ fonts: [TerminalFont]) throws {
        defaults.set(try JSONEncoder().encode(fonts), forKey: StorageKey.fonts)
    }

    func loadPreference() -> TerminalFontPreference {
        let timestamp = defaults.double(forKey: StorageKey.preferenceUpdatedAt)
        return TerminalFontPreference(
            primaryFamily: defaults.string(forKey: TerminalDefaults.fontNameKey)
                ?? TerminalDefaults.defaultFontName,
            cjkFamily: defaults.string(forKey: TerminalDefaults.cjkFontNameKey),
            updatedAt: timestamp > 0
                ? Date(timeIntervalSince1970: timestamp)
                : .distantPast
        )
    }

    func savePreference(_ preference: TerminalFontPreference) {
        defaults.set(preference.primaryFamily, forKey: TerminalDefaults.fontNameKey)
        if let cjkFamily = preference.cjkFamily {
            defaults.set(cjkFamily, forKey: TerminalDefaults.cjkFontNameKey)
        } else {
            defaults.removeObject(forKey: TerminalDefaults.cjkFontNameKey)
        }
        if preference.updatedAt == .distantPast {
            defaults.removeObject(forKey: StorageKey.preferenceUpdatedAt)
        } else {
            defaults.set(
                preference.updatedAt.timeIntervalSince1970,
                forKey: StorageKey.preferenceUpdatedAt
            )
        }
    }

    func importFont(
        from sourceURL: URL,
        now: Date
    ) throws -> TerminalFont {
        let inspection = try inspectFont(at: sourceURL)
        let filename = normalizedOriginalFilename(
            sourceURL.lastPathComponent,
            format: inspection.format
        )
        let font = try TerminalFontValidator.validateStoredFont(
            TerminalFont(
                familyNames: inspection.families.map(\.name),
                originalFilename: filename,
                fileSize: inspection.fileSize,
                sha256: inspection.sha256,
                updatedAt: now
            )
        )

        let destination = TerminalFontFilePaths.fontFileURL(
            for: font,
            root: rootDirectoryURL
        )
        do {
            try installVerifiedFile(from: sourceURL, to: destination, matching: font)
            try registerFont(at: destination)
            return font
        } catch {
            removeFile(for: font)
            throw error
        }
    }

    func installRemoteAsset(from sourceURL: URL, for untrustedFont: TerminalFont) throws {
        let font = try TerminalFontValidator.validateStoredFont(untrustedFont)
        guard !font.isDeleted else { return }
        let destination = TerminalFontFilePaths.fontFileURL(
            for: font,
            root: rootDirectoryURL
        )
        try installVerifiedFile(from: sourceURL, to: destination, matching: font)
    }

    func registerAvailableFonts(
        _ fonts: [TerminalFont]
    ) -> [TerminalFont.ID: [TerminalFontFamily]] {
        var available: [TerminalFont.ID: [TerminalFontFamily]] = [:]

        for font in fonts {
            if font.isDeleted {
                removeFile(for: font)
                continue
            }

            guard let url = existingFileURL(for: font) else { continue }
            let families: [TerminalFontFamily]
            do {
                guard try validatedFileSize(at: url) == font.fileSize else {
                    throw TerminalFontValidationError.checksumMismatch
                }
                families = try fontFamilies(at: url)
                guard Set(families.map(\.name)) == Set(font.familyNames) else {
                    throw TerminalFontValidationError.invalidFont
                }
            } catch {
                removeFile(for: font)
                continue
            }

            do {
                try registerFont(at: url)
                available[font.id] = families
            } catch {
                continue
            }
        }

        return available
    }

    func removeFile(for font: TerminalFont) {
        let fileURL = TerminalFontFilePaths.fontFileURL(
            for: font,
            root: rootDirectoryURL
        )
        unregisterFont(at: fileURL)

        let directory = TerminalFontFilePaths.fontDirectoryURL(
            for: font.id,
            root: rootDirectoryURL
        )
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.removeItem(at: directory)
    }

    func existingFileURL(for font: TerminalFont) -> URL? {
        let url = TerminalFontFilePaths.fontFileURL(
            for: font,
            root: rootDirectoryURL
        )
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func inspectFont(at url: URL) throws -> FontInspection {
        guard let format = TerminalFont.FileFormat(fileExtension: url.pathExtension) else {
            throw TerminalFontValidationError.unsupportedFormat
        }

        let fileSize = try validatedFileSize(at: url)
        let families = try fontFamilies(at: url)

        return FontInspection(
            families: families,
            format: format,
            fileSize: fileSize,
            sha256: try sha256(of: url)
        )
    }

    private func installVerifiedFile(
        from sourceURL: URL,
        to destinationURL: URL,
        matching font: TerminalFont
    ) throws {
        guard try validatedFileSize(at: sourceURL) == font.fileSize else {
            throw TerminalFontValidationError.checksumMismatch
        }

        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if let currentURL = existingFileURL(for: font),
           (try? verifyFile(at: currentURL, matching: font)) != nil {
            return
        }

        let incomingURL = directory.appendingPathComponent(
            ".incoming-\(font.id)",
            isDirectory: false
        )
        if fileManager.fileExists(atPath: incomingURL.path) {
            try fileManager.removeItem(at: incomingURL)
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: incomingURL)
            try verifyFile(at: incomingURL, matching: font)
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: incomingURL)
            } else {
                try fileManager.moveItem(at: incomingURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: incomingURL)
            throw error
        }
    }

    private func verifyFile(at url: URL, matching font: TerminalFont) throws {
        guard try validatedFileSize(at: url) == font.fileSize else {
            throw TerminalFontValidationError.checksumMismatch
        }
        guard try sha256(of: url) == font.sha256.lowercased() else {
            throw TerminalFontValidationError.checksumMismatch
        }
    }

    private func validatedFileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              let fileSize = Int64(exactly: size),
              fileSize > 0 else {
            throw TerminalFontValidationError.fileUnavailable
        }
        guard fileSize <= TerminalFontValidator.maximumFileSize else {
            throw TerminalFontValidationError.fileTooLarge
        }
        return fileSize
    }

    private func fontDescriptors(at url: URL) -> [CTFontDescriptor] {
        CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
    }

    private func fontFamilies(at url: URL) throws -> [TerminalFontFamily] {
        let descriptors = fontDescriptors(at: url)
        guard !descriptors.isEmpty else {
            throw TerminalFontValidationError.invalidFont
        }

        var familyNames = Set<String>()
        for descriptor in descriptors {
            guard let familyName = CTFontDescriptorCopyAttribute(
                descriptor,
                kCTFontFamilyNameAttribute
            ) as? String else {
                continue
            }
            let family = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !family.isEmpty else { continue }
            familyNames.insert(family)
        }

        let names = TerminalFontValidator.normalizedNames(Array(familyNames))
        guard !names.isEmpty else { throw TerminalFontValidationError.invalidFont }
        return names.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }.map {
            TerminalFontFamily(
                name: $0,
                source: .custom
            )
        }
    }

    private func registerFont(at url: URL) throws {
        var unmanagedError: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &unmanagedError) {
            return
        }

        let error = unmanagedError.map { $0.takeRetainedValue() as Error as NSError }
        guard error?.code != CTFontManagerError.alreadyRegistered.rawValue else { return }
        throw TerminalFontValidationError.registrationFailed(
            error?.localizedDescription ?? String(localized: "Unknown error")
        )
    }

    private func unregisterFont(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        var unmanagedError: Unmanaged<CFError>?
        _ = CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &unmanagedError)
        _ = unmanagedError?.takeRetainedValue()
    }

    private func normalizedOriginalFilename(
        _ filename: String,
        format: TerminalFont.FileFormat
    ) -> String {
        let value = URL(fileURLWithPath: filename).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard TerminalFontValidator.isValidOriginalFilename(value),
              TerminalFont.FileFormat(
                  fileExtension: URL(fileURLWithPath: value).pathExtension
              ) == format else {
            return "Imported Font.\(format.rawValue)"
        }
        return value
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated private enum StorageKey {
    static let fonts = "terminalCustomFontsV1"
    static let preferenceUpdatedAt = "terminalFontPreferenceUpdatedAt"
}

nonisolated private struct FontInspection: Sendable {
    let families: [TerminalFontFamily]
    let format: TerminalFont.FileFormat
    let fileSize: Int64
    let sha256: String
}

nonisolated private enum TerminalFontFilePaths {
    static func customFontsDirectoryURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> URL {
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return appSupport
            .appendingPathComponent(bundleIdentifier ?? "app.vivy.vvterm", isDirectory: true)
            .appendingPathComponent("CustomFonts", isDirectory: true)
    }

    static func fontDirectoryURL(for fontID: TerminalFont.ID, root: URL) -> URL {
        root.appendingPathComponent(fontID, isDirectory: true)
    }

    static func fontFileURL(for font: TerminalFont, root: URL) -> URL {
        fontDirectoryURL(for: font.id, root: root)
            .appendingPathComponent("font", isDirectory: false)
    }
}
