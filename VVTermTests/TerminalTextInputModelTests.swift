import Foundation
import Testing
@testable import VVTerm

struct TerminalTextInputModelTests {
    @Test
    func pinyinCommitClearsCompositionAndReanchorsNextComposition() {
        var model = TerminalTextInputModel()

        let initialEffects = model.handleSetMarkedText("wo yao chi fan", selectedRangeLocation: 13)
        #expect(initialEffects == [.syncPreedit("wo yao chi fan"), .didTextChange])
        #expect(model.markedText == "wo yao chi fan")
        #expect(model.markedTextStartIndex == 0)
        #expect(model.cursorIndex == 13)

        let operation = TerminalTextInputModel.insertOperation(for: "我", fromIMEComposition: model.hasActiveIMEComposition)
        #expect(operation == .text("我", cursorAdvance: 1))

        let commitEffects = model.handleInsert(operation)
        #expect(commitEffects.contains(.resetIMEContext))
        #expect(commitEffects.contains(.sendText("我")))
        #expect(model.markedText.isEmpty)
        #expect(model.markedTextStartIndex == nil)
        #expect(model.cursorIndex == 1)

        let nextEffects = model.handleSetMarkedText("wo", selectedRangeLocation: 2)
        #expect(nextEffects == [.syncPreedit("wo"), .didTextChange])
        #expect(model.markedText == "wo")
        #expect(model.markedTextStartIndex == 1)
        #expect(model.cursorIndex == 3)
    }

    @Test
    func japaneseReplacementCommitClearsCompositionAndUsesRangeStart() {
        var model = TerminalTextInputModel(cursorIndex: 5)

        _ = model.handleSetMarkedText("にほん", selectedRangeLocation: 3)
        #expect(model.markedTextStartIndex == 5)
        #expect(model.cursorIndex == 8)

        let effects = model.handleReplace(rangeStart: 5, text: "日")
        #expect(effects.contains(.resetIMEContext))
        #expect(effects.contains(.sendText("日")))
        #expect(model.markedText.isEmpty)
        #expect(model.markedTextStartIndex == nil)
        #expect(model.cursorIndex == 6)
    }

    @Test
    func hangulStyleMultiCharacterCommitUsesTextPath() {
        var model = TerminalTextInputModel()

        _ = model.handleSetMarkedText("gksrmf", selectedRangeLocation: 6)
        let operation = TerminalTextInputModel.insertOperation(for: "한글", fromIMEComposition: model.hasActiveIMEComposition)

        #expect(operation == .text("한글", cursorAdvance: "한글".utf16.count))

        let effects = model.handleInsert(operation)
        #expect(effects.contains(.sendText("한글")))
        #expect(!effects.contains(.sendTextKeyEvent("한글")))
        #expect(model.cursorIndex == "한글".utf16.count)
        #expect(model.markedText.isEmpty)
    }

    @Test
    func japaneseKanaCommitOfMultipleCharactersUsesTextPath() {
        var model = TerminalTextInputModel()

        _ = model.handleSetMarkedText("konnichiha", selectedRangeLocation: 10)
        let operation = TerminalTextInputModel.insertOperation(for: "こんにちは", fromIMEComposition: model.hasActiveIMEComposition)

        #expect(operation == .text("こんにちは", cursorAdvance: "こんにちは".utf16.count))

        let effects = model.handleInsert(operation)
        #expect(effects.contains(.resetIMEContext))
        #expect(effects.contains(.sendText("こんにちは")))
        #expect(model.cursorIndex == "こんにちは".utf16.count)
        #expect(model.markedText.isEmpty)
        #expect(model.markedTextStartIndex == nil)
    }

    @Test
    func unmarkWithoutCommitFlushesMarkedTextAndClearsComposition() {
        var model = TerminalTextInputModel()

        _ = model.handleSetMarkedText("nih", selectedRangeLocation: 3)
        let effects = model.handleUnmarkText()

        #expect(effects.contains(.sendText("nih")))
        #expect(effects.contains(.syncPreedit(nil)))
        #expect(effects.contains(.resetIMEContext))
        #expect(model.markedText.isEmpty)
        #expect(model.markedTextStartIndex == nil)
        #expect(model.cursorIndex == 3)
    }

    @Test
    func unmarkAfterCommittedTextDoesNotResendStaleComposition() {
        var model = TerminalTextInputModel()

        _ = model.handleSetMarkedText("wo", selectedRangeLocation: 2)
        _ = model.handleInsert(.text("我", cursorAdvance: 1))
        let effects = model.handleUnmarkText()

        #expect(effects == [.syncPreedit(nil)])
        #expect(model.markedText.isEmpty)
        #expect(model.markedTextStartIndex == nil)
        #expect(model.cursorIndex == 1)
    }

    @Test
    func deleteBackwardWhileComposingShrinksPreeditWithoutSendingBackspace() {
        var model = TerminalTextInputModel()

        _ = model.handleSetMarkedText("hang", selectedRangeLocation: 4)
        let effects = model.handleDeleteBackward()

        #expect(effects.contains(.syncPreedit("han")))
        #expect(!effects.contains(.sendSpecialKey(.backspace)))
        #expect(model.markedText == "han")
        #expect(model.markedTextStartIndex == 0)
        #expect(model.cursorIndex == 3)
    }

    @Test
    func singleCharacterAsciiRoutesAsKeyEventWhenNotComposing() {
        let operation = TerminalTextInputModel.insertOperation(for: "a", fromIMEComposition: false)
        #expect(operation == .keyEvent("a", cursorAdvance: 1))

        var model = TerminalTextInputModel()
        let effects = model.handleInsert(operation)
        #expect(effects == [.sendTextKeyEvent("a")])
        #expect(model.cursorIndex == 1)
    }

    @Test
    func emojiRoutesAsTextEvenOutsideIME() {
        let emoji = "👍🏽"
        let operation = TerminalTextInputModel.insertOperation(for: emoji, fromIMEComposition: false)
        #expect(operation == .text(emoji, cursorAdvance: emoji.utf16.count))
    }

    @Test
    func decomposedAccentRoutesAsTextOutsideIme() {
        let accented = "e\u{301}"
        let operation = TerminalTextInputModel.insertOperation(for: accented, fromIMEComposition: false)

        #expect(operation == .text(accented, cursorAdvance: accented.utf16.count))
    }

    @Test
    func multilineInsertNormalizesLineEndingsToCarriageReturns() {
        let operation = TerminalTextInputModel.insertOperation(for: "ni\r\nhao\rma", fromIMEComposition: false)
        #expect(operation == .text("ni\rhao\rma", cursorAdvance: "ni\nhao\nma".utf16.count))
    }

    @Test
    func carriageReturnRoutesAsEnterSpecialKey() {
        let operation = TerminalTextInputModel.insertOperation(for: "\r", fromIMEComposition: false)
        #expect(operation == .specialKey(.enter, cursorAdvance: 1))
    }

    @Test
    func setMarkedTextNilClearsExistingCompositionWithoutMovingCursor() {
        var model = TerminalTextInputModel(cursorIndex: 4)

        _ = model.handleSetMarkedText("pinyin", selectedRangeLocation: 6)
        let effects = model.handleSetMarkedText(nil, selectedRangeLocation: 0)

        #expect(effects == [.syncPreedit(nil), .didTextChange])
        #expect(model.markedText.isEmpty)
        #expect(model.markedTextStartIndex == nil)
        #expect(model.cursorIndex == 10)
    }

    @Test
    func setMarkedTextClampsSelectionToCompositionLength() {
        var model = TerminalTextInputModel(cursorIndex: 2)

        let effects = model.handleSetMarkedText("かな", selectedRangeLocation: 99)

        #expect(effects == [.syncPreedit("かな"), .didTextChange])
        #expect(model.markedTextStartIndex == 2)
        #expect(model.cursorIndex == 4)
    }

    @Test
    func setMarkedTextClampsNegativeSelectionToCompositionStart() {
        var model = TerminalTextInputModel(cursorIndex: 9)

        let effects = model.handleSetMarkedText("zhong", selectedRangeLocation: -4)

        #expect(effects == [.syncPreedit("zhong"), .didTextChange])
        #expect(model.markedTextStartIndex == 9)
        #expect(model.cursorIndex == 9)
    }

    @Test
    func updatingMarkedTextReusesOriginalCompositionAnchor() {
        var model = TerminalTextInputModel(cursorIndex: 7)

        _ = model.handleSetMarkedText("ni", selectedRangeLocation: 2)
        let effects = model.handleSetMarkedText("nihon", selectedRangeLocation: 3)

        #expect(effects == [.syncPreedit("nihon"), .didTextChange])
        #expect(model.markedTextStartIndex == 7)
        #expect(model.cursorIndex == 10)
    }

    @Test
    func repeatedCommitCancelCyclesKeepCursorAndAnchorConsistent() {
        var model = TerminalTextInputModel()

        _ = model.handleSetMarkedText("wo", selectedRangeLocation: 2)
        _ = model.handleInsert(.text("我", cursorAdvance: 1))
        #expect(model.cursorIndex == 1)

        _ = model.handleSetMarkedText("shi", selectedRangeLocation: 3)
        _ = model.handleUnmarkText()
        #expect(model.cursorIndex == 4)

        _ = model.handleSetMarkedText("fan", selectedRangeLocation: 3)
        _ = model.handleInsert(.text("饭", cursorAdvance: 1))
        #expect(model.cursorIndex == 5)
        #expect(model.markedText.isEmpty)
        #expect(model.markedTextStartIndex == nil)
    }

    @Test
    func numberTypedWhileComposingCommitsThroughTextPathAndResetsContext() {
        var model = TerminalTextInputModel()

        _ = model.handleSetMarkedText("wo yao chi fan", selectedRangeLocation: 13)
        let operation = TerminalTextInputModel.insertOperation(for: "1", fromIMEComposition: model.hasActiveIMEComposition)
        let effects = model.handleInsert(operation)

        #expect(operation == .text("1", cursorAdvance: 1))
        #expect(effects.contains(.resetIMEContext))
        #expect(effects.contains(.sendText("1")))
        #expect(!effects.contains(.sendTextKeyEvent("1")))
        #expect(model.cursorIndex == 1)
    }

    @Test
    func emptyMarkedTextShellCanBeReusedByNextComposition() {
        var model = TerminalTextInputModel(cursorIndex: 4)

        let emptyEffects = model.handleSetMarkedText("", selectedRangeLocation: 0)
        #expect(emptyEffects == [.syncPreedit(""), .didTextChange])
        #expect(model.hasActiveIMEComposition)
        #expect(model.markedTextStartIndex == 4)
        #expect(model.cursorIndex == 4)

        let nextEffects = model.handleSetMarkedText("wo", selectedRangeLocation: 2)
        #expect(nextEffects == [.syncPreedit("wo"), .didTextChange])
        #expect(model.markedText == "wo")
        #expect(model.markedTextStartIndex == 4)
        #expect(model.cursorIndex == 6)
    }

    @Test
    func enterWhileComposingCommitsCompositionThenSendsEnter() {
        var model = TerminalTextInputModel()

        _ = model.handleSetMarkedText("nihon", selectedRangeLocation: 5)
        let operation = TerminalTextInputModel.insertOperation(for: "\n", fromIMEComposition: model.hasActiveIMEComposition)
        let effects = model.handleInsert(operation)

        #expect(operation == .specialKey(.enter, cursorAdvance: 1))
        #expect(effects.contains(.resetIMEContext))
        #expect(effects.contains(.sendSpecialKey(.enter)))
        #expect(model.cursorIndex == 1)
    }

    @Test
    func tabOutsideCompositionRoutesAsSpecialKey() {
        var model = TerminalTextInputModel(cursorIndex: 2)

        let operation = TerminalTextInputModel.insertOperation(for: "\t", fromIMEComposition: false)
        let effects = model.handleInsert(operation)

        #expect(operation == .specialKey(.tab, cursorAdvance: 1))
        #expect(effects == [.sendSpecialKey(.tab)])
        #expect(model.cursorIndex == 3)
    }

    @Test
    func deleteBackwardWithoutCompositionSendsTerminalBackspaceAndClampsCursor() {
        var model = TerminalTextInputModel(cursorIndex: 0)

        let firstEffects = model.handleDeleteBackward()
        #expect(firstEffects == [.sendSpecialKey(.backspace)])
        #expect(model.cursorIndex == 0)

        model.cursorIndex = 3
        let secondEffects = model.handleDeleteBackward()
        #expect(secondEffects == [.sendSpecialKey(.backspace)])
        #expect(model.cursorIndex == 2)
    }

    @Test
    func deleteBackwardClearsEmptyCompositionShell() {
        var model = TerminalTextInputModel(markedText: "", markedTextStartIndex: 6, didCommitMarkedText: false, cursorIndex: 9)

        let effects = model.handleDeleteBackward()

        #expect(effects.contains(.syncPreedit(nil)))
        #expect(model.markedText.isEmpty)
        #expect(model.markedTextStartIndex == nil)
        #expect(model.cursorIndex == 6)
    }

    @Test
    func replaceDuringCompositionWithoutRangeStartAdvancesFromCompositionAnchor() {
        var model = TerminalTextInputModel(cursorIndex: 3)

        _ = model.handleSetMarkedText("nihon", selectedRangeLocation: 5)
        let effects = model.handleReplace(rangeStart: nil, text: "日")

        #expect(effects.contains(.resetIMEContext))
        #expect(effects.contains(.sendText("日")))
        #expect(model.markedText.isEmpty)
        #expect(model.markedTextStartIndex == nil)
        #expect(model.cursorIndex == 9)
    }

    @Test
    func replaceWithoutCompositionEmitsTextChangeAndUsesProvidedRangeStart() {
        var model = TerminalTextInputModel(cursorIndex: 10)

        let effects = model.handleReplace(rangeStart: 4, text: "日本語")

        #expect(effects == [.sendText("日本語"), .didTextChange])
        #expect(model.cursorIndex == 7)
    }

    @Test
    func multiCharacterAsciiOutsideImeUsesTextPath() {
        let operation = TerminalTextInputModel.insertOperation(for: "ssh", fromIMEComposition: false)
        #expect(operation == .text("ssh", cursorAdvance: 3))
    }

    @Test
    func precomposedSingleScalarAccentStillUsesKeyEventPath() {
        let operation = TerminalTextInputModel.insertOperation(for: "é", fromIMEComposition: false)
        #expect(operation == .keyEvent("é", cursorAdvance: 1))
    }

    @Test
    func singleCommittedHanCharacterOutsideImeStillRoutesAsKeyEvent() {
        let operation = TerminalTextInputModel.insertOperation(for: "我", fromIMEComposition: false)
        #expect(operation == .keyEvent("我", cursorAdvance: 1))
    }

    @Test
    func deleteBackwardDropsWholeGraphemeClusterFromMarkedText() {
        var model = TerminalTextInputModel()

        _ = model.handleSetMarkedText("👍🏽a", selectedRangeLocation: 3)
        let effects = model.handleDeleteBackward()

        #expect(effects.contains(.syncPreedit("👍🏽")))
        #expect(model.markedText == "👍🏽")
        #expect(model.cursorIndex == "👍🏽".utf16.count)
    }
}
