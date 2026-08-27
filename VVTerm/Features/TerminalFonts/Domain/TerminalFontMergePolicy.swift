import Foundation

nonisolated enum TerminalFontMergePolicy {
    static func normalized(_ fonts: [TerminalFont]) -> [TerminalFont] {
        merge(local: fonts, remote: [])
    }

    static func merge(local: [TerminalFont], remote: [TerminalFont]) -> [TerminalFont] {
        var fontsByID: [TerminalFont.ID: TerminalFont] = [:]

        for font in local + remote {
            guard let font = try? TerminalFontValidator.validateStoredFont(font) else {
                continue
            }
            if let existing = fontsByID[font.id], existing.updatedAt >= font.updatedAt {
                continue
            }
            fontsByID[font.id] = font
        }

        return fontsByID.values.sorted {
            if $0.displayName != $1.displayName {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            }
            return $0.id < $1.id
        }
    }
}
