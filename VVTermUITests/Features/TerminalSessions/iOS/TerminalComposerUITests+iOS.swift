#if os(iOS)
import XCTest

final class TerminalComposerUITests: XCTestCase {
    @MainActor
    func testChatDraftAttachmentsRemovalAndSend() {
        let app = launch()
        app.buttons["vvterm.composer.toggle"].tap()
        let editor = app.textViews["vvterm.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        XCTAssertLessThan(editor.frame.height, 65)
        XCTAssertFalse(app.buttons["vvterm.composer.close"].exists)
        let compactHeight = editor.frame.height
        editor.typeText("review\nthese")
        XCTAssertGreaterThan(editor.frame.height, compactHeight)
        XCTAssertEqual(app.staticTexts["composer.test.bytes"].label, "")
        app.buttons["composer.test.add"].tap()
        let remove = app.buttons["vvterm.attachment.remove.one.png"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native composer with attachment"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["vvterm.composer.send"].tap()
        let sent = app.staticTexts["composer.test.sent"]
        expectation(for: NSPredicate(format: "label == %@", "review\nthese /tmp/two.pdf"), evaluatedWith: sent)
        waitForExpectations(timeout: 8)
        let bytes = app.staticTexts["composer.test.bytes"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "/tmp/two.pdf<CR>"), evaluatedWith: bytes)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(bytes.label.components(separatedBy: "/tmp/two.pdf").count, 2)
        XCTAssertFalse(app.buttons["vvterm.attachment.remove.two.pdf"].exists)
        XCTAssertEqual(editor.value as? String, "")
        app.buttons["vvterm.composer.toggle"].tap()
        XCTAssertFalse(editor.exists)
        XCTAssertTrue(app.buttons["vvterm.keyboard.accessory.attachments"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFailedUploadKeepsDraftForRetry() {
        let app = launch()
        app.buttons["vvterm.composer.toggle"].tap()
        app.textViews["vvterm.composer.text"].tap()
        app.textViews["vvterm.composer.text"].typeText("keep")
        app.buttons["composer.test.fail"].tap()
        XCTAssertEqual(app.buttons["composer.test.fail"].label, "Uploads fail")
        app.buttons["composer.test.add"].tap()
        XCTAssertTrue(app.buttons["vvterm.attachment.remove.two.pdf"].waitForExistence(timeout: 5))
        app.buttons["vvterm.composer.send"].tap()
        let errorAppeared = app.staticTexts["vvterm.composer.error"].waitForExistence(timeout: 5)
        if !errorAppeared {
            add(XCTAttachment(screenshot: app.screenshot()))
            print(app.debugDescription)
        }
        XCTAssertTrue(errorAppeared)
        XCTAssertEqual(app.staticTexts["composer.test.sent"].label, "No input sent")
        XCTAssertEqual(app.textViews["vvterm.composer.text"].value as? String, "keep")
        app.buttons["composer.test.fail"].tap()
        app.buttons["vvterm.composer.send"].tap()
        expectation(for: NSPredicate(format: "label == %@", "keep /tmp/one.png /tmp/two.pdf"), evaluatedWith: app.staticTexts["composer.test.sent"])
        waitForExpectations(timeout: 8)
    }

    @MainActor
    func testDirectAttachmentsOrderVisibilityAndPickerCancel() {
        let app = launch()
        let attachment = app.buttons["vvterm.keyboard.accessory.attachments"]
        XCTAssertTrue(attachment.waitForExistence(timeout: 8))
        let voice = app.buttons["vvterm.keyboard.accessory.voice"]
        XCTAssertLessThan(voice.frame.midX, attachment.frame.midX)
        attachment.tap()
        XCTAssertTrue(app.buttons["vvterm.attachments.files"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertEqual(app.staticTexts["composer.test.sent"].label, "No input sent")
        let visibility = app.switches["composer.test.visibility"]
        visibility.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(visibility.value as? String, "0")
        XCTAssertFalse(attachment.exists)
        app.buttons["composer.test.add"].tap()
        expectation(for: NSPredicate(format: "label == %@", "/tmp/one.png /tmp/two.pdf"), evaluatedWith: app.staticTexts["composer.test.sent"])
        waitForExpectations(timeout: 8)
        XCTAssertEqual(app.staticTexts["composer.test.bytes"].label, "/tmp/one.png /tmp/two.pdf")
        app.buttons["vvterm.composer.toggle"].tap()
        XCTAssertTrue(app.buttons["vvterm.composer.attach"].exists)
    }

    @MainActor
    func testSavedInputModeSettingControlsComposer() {
        let app = launch()
        app.buttons["composer.test.settings"].tap()
        app.segmentedControls["vvterm.input-mode"].buttons["Chat Mode"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.textViews["vvterm.composer.text"].waitForExistence(timeout: 5))
        app.buttons["composer.test.settings"].tap()
        app.segmentedControls["vvterm.input-mode"].buttons["Normal Mode"].tap()
        app.buttons["Done"].tap()
        XCTAssertFalse(app.textViews["vvterm.composer.text"].exists)
        XCTAssertTrue(app.buttons["vvterm.keyboard.accessory.attachments"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--vvterm-ui-test-composer", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["vvterm.composer.toggle"].waitForExistence(timeout: 10))
        return app
    }
}
#endif
