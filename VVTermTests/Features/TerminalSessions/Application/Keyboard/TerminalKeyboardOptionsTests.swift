#if os(iOS)
import XCTest
import UIKit
@testable import VVTerm

@MainActor
final class TerminalKeyboardOptionsTests: XCTestCase {
    func testNormalModeUsesKeyboardOptions() {
        let view = TerminalIMEProxyTextView()
        view.applyKeyboardOptions([.autocorrection, .capitalization, .spellChecking, .inlinePrediction, .smartPunctuation, .smartSpacing])
        XCTAssertEqual(view.autocorrectionType, .default)
        XCTAssertEqual(view.autocapitalizationType, .sentences)
        XCTAssertEqual(view.spellCheckingType, .default)
        XCTAssertEqual(view.smartQuotesType, .default)
        XCTAssertEqual(view.smartDashesType, .default)
        XCTAssertEqual(view.smartInsertDeleteType, .default)
        if #available(iOS 17.0, *) { XCTAssertEqual(view.inlinePredictionType, .default) }
        view.applyKeyboardOptions([])
        XCTAssertEqual(view.autocorrectionType, .no)
        XCTAssertEqual(view.autocapitalizationType, .none)
        XCTAssertEqual(view.spellCheckingType, .no)
        XCTAssertEqual(view.smartQuotesType, .no)
        XCTAssertEqual(view.smartDashesType, .no)
        XCTAssertEqual(view.smartInsertDeleteType, .no)
        if #available(iOS 17.0, *) { XCTAssertEqual(view.inlinePredictionType, .no) }
    }

    func testCommandDefaultsAndEnabledOptionsKeepDraftUnchanged() {
        let view = ComposerTextView()
        view.text = "git chekc --name='a--b'"
        let draft = view.text
        view.applyKeyboardOptions([])
        XCTAssertEqual(view.autocorrectionType, .no)
        XCTAssertEqual(view.autocapitalizationType, .none)
        XCTAssertEqual(view.spellCheckingType, .no)
        XCTAssertEqual(view.smartQuotesType, .no)
        XCTAssertEqual(view.smartDashesType, .no)
        XCTAssertEqual(view.smartInsertDeleteType, .no)
        if #available(iOS 17.0, *) { XCTAssertEqual(view.inlinePredictionType, .no) }
        let options: TerminalKeyboardOptions = [.autocorrection, .capitalization, .spellChecking,
                                                        .inlinePrediction, .smartPunctuation, .smartSpacing]
        view.applyKeyboardOptions(options)
        XCTAssertEqual(view.autocorrectionType, .default)
        XCTAssertEqual(view.autocapitalizationType, .sentences)
        XCTAssertEqual(view.spellCheckingType, .default)
        XCTAssertEqual(view.smartQuotesType, .default)
        XCTAssertEqual(view.smartDashesType, .default)
        XCTAssertEqual(view.smartInsertDeleteType, .default)
        if #available(iOS 17.0, *) { XCTAssertEqual(view.inlinePredictionType, .default) }
        view.applyKeyboardOptions(options)
        XCTAssertEqual(view.text, draft)
        view.applyKeyboardOptions([])
        XCTAssertEqual(view.text, draft)
    }
}
#endif
