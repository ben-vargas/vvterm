import Foundation

nonisolated struct TerminalKeyboardOptions: OptionSet, Sendable {
    let rawValue: Int
    static let preferenceKey = "terminalComposerKeyboardOptions"
    static let autocorrection = Self(rawValue: 1 << 0)
    static let capitalization = Self(rawValue: 1 << 1)
    static let spellChecking = Self(rawValue: 1 << 2)
    static let inlinePrediction = Self(rawValue: 1 << 3)
    static let smartPunctuation = Self(rawValue: 1 << 4)
    static let smartSpacing = Self(rawValue: 1 << 5)
}
