import Foundation

enum TerminalThemeValidationError: LocalizedError {
    case emptyContent
    case invalidLine(line: Int)
    case invalidHex(line: Int)
    case invalidPalette(line: Int)
    case missingRequiredKey(String)
    case invalidName
    case themeNotFound

    var errorDescription: String? {
        switch self {
        case .emptyContent:
            return String(localized: "Theme content is empty.")
        case .invalidLine(let line):
            return String(
                format: String(localized: "Invalid theme line %lld. Expected key/value format."),
                Int64(line)
            )
        case .invalidHex(let line):
            return String(
                format: String(localized: "Invalid hex color at line %lld. Use #RRGGBB."),
                Int64(line)
            )
        case .invalidPalette(let line):
            return String(
                format: String(localized: "Invalid palette value at line %lld. Expected N=#RRGGBB where N is 0...15."),
                Int64(line)
            )
        case .missingRequiredKey(let key):
            return String(
                format: String(localized: "Theme is missing required key: %@."),
                key
            )
        case .invalidName:
            return String(localized: "Theme name contains invalid characters.")
        case .themeNotFound:
            return String(localized: "Theme no longer exists.")
        }
    }
}

enum TerminalThemeValidator {
    private static let colorKeys = Set([
        "background",
        "foreground",
        "cursor-color",
        "cursor-text",
        "selection-background",
        "selection-foreground"
    ])

    nonisolated static func isValidHexColor(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = normalized.hasPrefix("#") ? String(normalized.dropFirst()) : normalized
        guard hex.count == 6 else { return false }
        return hex.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789ABCDEFabcdef").contains($0)
        }
    }

    nonisolated static func normalizeHexColor(_ value: String) -> String? {
        guard isValidHexColor(value) else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = normalized.hasPrefix("#") ? String(normalized.dropFirst()) : normalized
        return "#\(hex.uppercased())"
    }

    nonisolated static func validateAndNormalizeThemeContent(_ rawContent: String) throws -> String {
        let lines = rawContent.components(separatedBy: .newlines)
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw TerminalThemeValidationError.emptyContent
        }

        var normalizedLines: [String] = []
        var seenBackground = false
        var seenForeground = false

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                throw TerminalThemeValidationError.invalidLine(line: lineNumber)
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            if key == "palette" {
                let paletteParts = value.split(separator: "=", maxSplits: 1)
                guard paletteParts.count == 2,
                      let index = Int(paletteParts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                      (0...15).contains(index),
                      let color = normalizeHexColor(String(paletteParts[1])) else {
                    throw TerminalThemeValidationError.invalidPalette(line: lineNumber)
                }
                normalizedLines.append("palette = \(index)=\(color)")
                continue
            }

            if colorKeys.contains(key) {
                guard let color = normalizeHexColor(value) else {
                    throw TerminalThemeValidationError.invalidHex(line: lineNumber)
                }
                normalizedLines.append("\(key) = \(color)")

                if key == "background" { seenBackground = true }
                if key == "foreground" { seenForeground = true }
                continue
            }

            normalizedLines.append("\(key) = \(value)")
        }

        guard seenBackground else {
            throw TerminalThemeValidationError.missingRequiredKey("background")
        }
        guard seenForeground else {
            throw TerminalThemeValidationError.missingRequiredKey("foreground")
        }

        return normalizedLines.joined(separator: "\n") + "\n"
    }
}
