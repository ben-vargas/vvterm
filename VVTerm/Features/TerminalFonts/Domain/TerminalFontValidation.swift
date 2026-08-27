import Foundation

nonisolated enum TerminalFontValidationError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat
    case fileTooLarge
    case invalidFont
    case invalidMetadata
    case checksumMismatch
    case fileUnavailable
    case registrationFailed(String)
    case requiresPro

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return String(localized: "Choose a TTF, OTF, TTC, or OTC font file.")
        case .fileTooLarge:
            return String(localized: "Font files must be 48 MB or smaller.")
        case .invalidFont:
            return String(localized: "The selected file is not a valid font.")
        case .invalidMetadata:
            return String(localized: "The font information is invalid.")
        case .checksumMismatch:
            return String(localized: "The font file is incomplete or damaged.")
        case .fileUnavailable:
            return String(localized: "The font file is not available on this device.")
        case .registrationFailed(let message):
            return String(
                format: String(localized: "VVTerm could not load this font: %@"),
                message
            )
        case .requiresPro:
            return String(localized: "Custom and CJK fonts require Pro.")
        }
    }
}

nonisolated enum TerminalFontValidator {
    static let maximumFileSize: Int64 = 48 * 1_024 * 1_024
    private static let maximumFamilyCount = 64
    private static let maximumNameLength = 256
    private static let normalizationLocale = Locale(identifier: "en_US_POSIX")

    static func validateStoredFont(_ font: TerminalFont) throws -> TerminalFont {
        let families = normalizedNames(font.familyNames)
        guard !families.isEmpty,
              families.count <= maximumFamilyCount,
              families.allSatisfy(isValidName),
              font.fileSize > 0,
              font.fileSize <= maximumFileSize,
              isValidSHA256(font.sha256),
              isValidOriginalFilename(font.originalFilename),
              TerminalFont.FileFormat(
                  fileExtension: URL(fileURLWithPath: font.originalFilename).pathExtension
              ) != nil,
              font.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              font.deletedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              font.deletedAt.map({ $0 <= font.updatedAt }) ?? true else {
            throw TerminalFontValidationError.invalidMetadata
        }

        return TerminalFont(
            familyNames: families,
            originalFilename: font.originalFilename,
            fileSize: font.fileSize,
            sha256: font.sha256,
            updatedAt: font.updatedAt,
            deletedAt: font.deletedAt
        )
    }

    static func validatePreference(
        _ preference: TerminalFontPreference
    ) throws -> TerminalFontPreference {
        let normalized = TerminalFontPreference(
            primaryFamily: preference.primaryFamily,
            cjkFamily: preference.cjkFamily,
            updatedAt: preference.updatedAt
        )
        let names = [normalized.primaryFamily]
            + (normalized.cjkFamily.map { [$0] } ?? [])
        guard normalized.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              names.allSatisfy(isValidName) else {
            throw TerminalFontValidationError.invalidMetadata
        }
        return normalized
    }

    static func normalizedNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { name in
            let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = value.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: normalizationLocale
            )
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }

    static func isValidOriginalFilename(_ filename: String) -> Bool {
        let value = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maximumNameLength else { return false }
        return value == URL(fileURLWithPath: value).lastPathComponent
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isValidName(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= maximumNameLength
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isValidSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
        }
    }
}
