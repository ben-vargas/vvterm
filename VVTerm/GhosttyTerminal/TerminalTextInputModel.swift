import Foundation

struct TerminalTextInputModel {
    enum SpecialKey: Equatable {
        case enter
        case tab
        case backspace
    }

    enum InsertOperation: Equatable {
        case text(String, cursorAdvance: Int)
        case keyEvent(String, cursorAdvance: Int)
        case specialKey(SpecialKey, cursorAdvance: Int)
    }

    enum Effect: Equatable {
        case willTextChange
        case willSelectionChange
        case didTextChange
        case didSelectionChange
        case syncPreedit(String?)
        case resetIMEContext
        case sendText(String)
        case sendTextKeyEvent(String)
        case sendSpecialKey(SpecialKey)
    }

    var markedText: String = ""
    var markedTextStartIndex: Int?
    var didCommitMarkedText = false
    var cursorIndex = 0

    var hasActiveIMEComposition: Bool {
        !markedText.isEmpty || markedTextStartIndex != nil
    }

    static func shouldSendSoftwareKeyboardTextAsKeyEvent(_ text: String, fromIMEComposition: Bool) -> Bool {
        guard !fromIMEComposition else { return false }
        guard text.count == 1 else { return false }
        return text.unicodeScalars.count == 1
    }

    static func insertOperation(for text: String, fromIMEComposition: Bool) -> InsertOperation {
        if text == "\n" || text == "\r" {
            return .specialKey(.enter, cursorAdvance: 1)
        }
        if text == "\t" {
            return .specialKey(.tab, cursorAdvance: 1)
        }

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.contains("\n") {
            return .text(
                normalized.replacingOccurrences(of: "\n", with: "\r"),
                cursorAdvance: normalized.utf16.count
            )
        }

        if shouldSendSoftwareKeyboardTextAsKeyEvent(text, fromIMEComposition: fromIMEComposition) {
            return .keyEvent(text, cursorAdvance: text.utf16.count)
        }

        return .text(text, cursorAdvance: text.utf16.count)
    }

    mutating func handleInsert(_ operation: InsertOperation) -> [Effect] {
        let wasComposing = hasActiveIMEComposition
        var effects: [Effect] = []

        if wasComposing {
            let start = markedTextStartIndex ?? cursorIndex
            effects.append(.willTextChange)
            effects.append(.willSelectionChange)
            didCommitMarkedText = true
            markedText = ""
            markedTextStartIndex = nil
            cursorIndex = start
            effects.append(.syncPreedit(nil))
            effects.append(.resetIMEContext)
        }

        switch operation {
        case let .text(text, cursorAdvance):
            effects.append(.sendText(text))
            cursorIndex += cursorAdvance
        case let .keyEvent(text, cursorAdvance):
            effects.append(.sendTextKeyEvent(text))
            cursorIndex += cursorAdvance
        case let .specialKey(key, cursorAdvance):
            effects.append(.sendSpecialKey(key))
            cursorIndex += cursorAdvance
        }

        if wasComposing {
            effects.append(.didTextChange)
            effects.append(.didSelectionChange)
        }

        return effects
    }

    mutating func handleDeleteBackward() -> [Effect] {
        if hasActiveIMEComposition {
            let start = markedTextStartIndex ?? cursorIndex
            var effects: [Effect] = [.willTextChange, .willSelectionChange]
            didCommitMarkedText = false

            if !markedText.isEmpty {
                let updatedText = String(markedText.dropLast())
                if updatedText.isEmpty {
                    markedText = ""
                    markedTextStartIndex = nil
                    cursorIndex = start
                    effects.append(.syncPreedit(nil))
                } else {
                    markedText = updatedText
                    cursorIndex = start + updatedText.utf16.count
                    effects.append(.syncPreedit(updatedText))
                }
            } else {
                markedText = ""
                markedTextStartIndex = nil
                cursorIndex = start
                effects.append(.syncPreedit(nil))
            }

            effects.append(.didTextChange)
            effects.append(.didSelectionChange)
            return effects
        }

        cursorIndex = max(cursorIndex - 1, 0)
        return [.sendSpecialKey(.backspace)]
    }

    mutating func handleReplace(rangeStart: Int?, text: String) -> [Effect] {
        let wasComposing = hasActiveIMEComposition
        var effects: [Effect] = []

        if wasComposing {
            effects.append(.willTextChange)
            effects.append(.willSelectionChange)
            didCommitMarkedText = true
            markedText = ""
            markedTextStartIndex = nil
            effects.append(.syncPreedit(nil))
            effects.append(.resetIMEContext)
        }

        effects.append(.sendText(text))
        if let rangeStart {
            cursorIndex = rangeStart + text.utf16.count
        } else if !text.isEmpty {
            cursorIndex += text.utf16.count
        }

        effects.append(.didTextChange)
        if wasComposing {
            effects.append(.didSelectionChange)
        }

        return effects
    }

    mutating func handleSetMarkedText(_ text: String?, selectedRangeLocation: Int) -> [Effect] {
        if let text {
            let composedText = text.precomposedStringWithCanonicalMapping
            didCommitMarkedText = false
            markedText = composedText
            let start = markedTextStartIndex ?? cursorIndex
            markedTextStartIndex = start
            let selectionOffset = min(max(selectedRangeLocation, 0), composedText.utf16.count)
            cursorIndex = start + selectionOffset
            return [.syncPreedit(composedText), .didTextChange]
        }

        didCommitMarkedText = false
        markedText = ""
        markedTextStartIndex = nil
        return [.syncPreedit(nil), .didTextChange]
    }

    mutating func handleUnmarkText() -> [Effect] {
        let hadMarkedText = hasActiveIMEComposition
        var effects: [Effect] = []

        if !didCommitMarkedText, !markedText.isEmpty {
            effects.append(.willTextChange)
            effects.append(.willSelectionChange)
            effects.append(.sendText(markedText))
            cursorIndex += markedText.utf16.count
        }

        markedText = ""
        markedTextStartIndex = nil
        didCommitMarkedText = false
        effects.append(.syncPreedit(nil))

        if hadMarkedText {
            effects.append(.resetIMEContext)
            effects.append(.didTextChange)
            effects.append(.didSelectionChange)
        }

        return effects
    }
}
