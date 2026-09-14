#if os(iOS)
import XCTest

final class TerminalComposerUITests: XCTestCase {
    @MainActor
    func testChatLinksWorkWithoutTakingTerminalKeyboardOwnership() throws {
        let app = launch(arguments: ["--composer-content-fixture"])
        app.buttons["vvterm.composer.toggle"].tap()
        let terminal = app.otherElements["composer.test.terminal"]
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        let point = try contentPoint(in: app, row: 2.5)
        point.tap()
        let alert = app.alerts["Open Link"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["https://example.com/chat"].exists)
        alert.buttons["Cancel"].tap()
        XCTAssertEqual(app.staticTexts["composer.test.sent"].label, "No input sent")
        point.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Open"].tap()
        XCTAssertEqual(app.staticTexts["composer.test.sent"].label, "https://example.com/chat")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["Read selection"].tap()
        XCTAssertTrue(app.staticTexts["composer.test.content"].label.contains("terminalInput=false"))
    }

    @MainActor
    func testChatAndNormalWordAndLineSelection() throws {
        let app = launch(arguments: ["--composer-content-fixture"])
        for chat in [false, true] {
            if chat { app.buttons["vvterm.composer.toggle"].tap() }
            let point = try contentPoint(in: app, row: 1.5)
            point.doubleTap()
            app.buttons["Read selection"].tap()
            XCTAssertEqual(selectedText(in: app), "two")
            // Tap away before starting a fresh three-tap gesture.
            app.otherElements["composer.test.terminal"].coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)).tap()
            app.buttons["Read selection"].tap()
            app.otherElements["composer.test.terminal"].tap(withNumberOfTaps: 3, numberOfTouches: 1)
            app.buttons["Read selection"].tap()
            XCTAssertEqual(selectedText(in: app), "one two three")
            if chat {
                XCTAssertTrue(app.staticTexts["composer.test.content"].label.contains("terminalInput=false"))
            }
            app.otherElements["composer.test.terminal"].coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)).tap()
            try contentPoint(in: app, row: 1.5).press(forDuration: 0.6)
            app.buttons["Read selection"].tap()
            XCTAssertEqual(selectedText(in: app), "two")
        }
    }

    @MainActor
    func testKeyboardMenuTogglesChatFocus() {
        let app = launch()
        app.buttons["vvterm.composer.toggle"].tap()
        let editor = app.textViews["vvterm.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["composer.test.menu"].tap()
        app.buttons["Keyboard"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(editor.isHittable)
        app.buttons["composer.test.menu"].tap()
        app.buttons["Keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText("from menu")
        XCTAssertEqual(editor.value as? String, "from menu")
    }

    @MainActor
    func testTerminalTapDismissesChatKeyboardAndEditorTapRestoresIt() {
        let app = launch()
        app.buttons["vvterm.composer.toggle"].tap()
        let editor = app.textViews["vvterm.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("keep draft")
        let terminal = app.otherElements["composer.test.terminal"]
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let dismissed = XCTAttachment(screenshot: app.screenshot())
        dismissed.name = "Chat after terminal tap"
        dismissed.lifetime = .keepAlways
        add(dismissed)
        XCTAssertEqual(app.staticTexts["composer.test.terminal-touch"].label, "focusTap=true hidden=true responder=none", app.debugDescription)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(editor.isHittable)
        XCTAssertEqual(editor.value as? String, "keep draft")
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        // UITextView's default accessibility tap point is at the start of the text.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText(" again")
        XCTAssertEqual(editor.value as? String, "keep draft again")
        XCTAssertEqual(app.staticTexts["composer.test.bytes"].label, "")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Chat focus restored"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testChatDraftAttachmentsRemovalAndSend() {
        let app = launch()
        app.buttons["vvterm.composer.toggle"].tap()
        let editor = app.textViews["vvterm.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        XCTAssertLessThanOrEqual(editor.frame.height, 42)
        XCTAssertFalse(app.buttons["vvterm.composer.close"].exists)
        let compactHeight = editor.frame.height
        editor.typeText("review\nthese")
        XCTAssertGreaterThan(editor.frame.height, compactHeight)
        XCTAssertEqual(app.staticTexts["composer.test.bytes"].label, "")
        app.buttons["composer.test.add"].tap()
        let remove = app.buttons["vvterm.attachment.remove.one.png"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["vvterm.attachment.preview.one.png"].waitForExistence(timeout: 5))
        let plus = app.buttons["vvterm.composer.attach"]
        XCTAssertLessThan(plus.frame.maxX, app.images["vvterm.attachment.preview.one.png"].frame.minX)
        XCTAssertEqual(app.staticTexts["composer.test.bytes"].label, "")
        let previews = XCTAttachment(screenshot: app.screenshot())
        previews.name = "Attachments stay in draft"
        previews.lifetime = .keepAlways
        add(previews)
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
    func testDirectAttachmentsOrderVisibilityAndMenuDismissal() {
        let app = launch()
        let attachment = app.buttons["vvterm.keyboard.accessory.attachments"]
        XCTAssertTrue(attachment.waitForExistence(timeout: 8))
        let voice = app.buttons["vvterm.keyboard.accessory.voice"]
        XCTAssertLessThan(voice.frame.midX, attachment.frame.midX)
        attachment.tap()
        XCTAssertTrue(app.buttons["vvterm.attachments.files"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Cancel"].exists)
        app.buttons["vvterm.attachments.files"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(attachment.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["vvterm.composer.error"].exists)
        attachment.tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.35)).tap()
        XCTAssertEqual(app.staticTexts["composer.test.sent"].label, "No input sent")
        let visibility = app.switches["composer.test.visibility"]
        visibility.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(visibility.value as? String, "0")
        XCTAssertFalse(attachment.exists)
        app.buttons["composer.test.add"].tap()
        XCTAssertFalse(app.textViews["vvterm.composer.text"].exists)
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
        app.buttons["Input Mode"].tap()
        app.segmentedControls["vvterm.input-mode"].buttons["Chat Mode"].tap()
        XCTAssertEqual(app.otherElements["vvterm.settings.inputMode.preview"].value as? String, "Chat Mode")
        XCTAssertTrue(app.staticTexts["Review text and attachments before sending. Send also presses Enter."].exists)
        let chatPreview = XCTAttachment(screenshot: app.screenshot())
        chatPreview.name = "Chat Mode settings preview"
        chatPreview.lifetime = .keepAlways
        add(chatPreview)
        app.buttons["BackButton"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.textViews["vvterm.composer.text"].waitForExistence(timeout: 5))
        app.buttons["composer.test.settings"].tap()
        app.buttons["Input Mode"].tap()
        app.segmentedControls["vvterm.input-mode"].buttons["Normal Mode"].tap()
        XCTAssertEqual(app.otherElements["vvterm.settings.inputMode.preview"].value as? String, "Normal Mode")
        XCTAssertTrue(app.staticTexts["Type directly in the terminal. Attachments are sent immediately."].exists)
        let normalPreview = XCTAttachment(screenshot: app.screenshot())
        normalPreview.name = "Normal Mode settings preview"
        normalPreview.lifetime = .keepAlways
        add(normalPreview)
        app.buttons["BackButton"].tap()
        app.buttons["Done"].tap()
        XCTAssertFalse(app.textViews["vvterm.composer.text"].exists)
        XCTAssertTrue(app.buttons["vvterm.keyboard.accessory.attachments"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testVoiceButtonRecordsIntoEditableDraftWithoutSending() {
        let app = launch()
        app.buttons["vvterm.composer.toggle"].tap()
        let record = app.buttons["vvterm.composer.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["vvterm.composer.send"].exists)
        let emptyScreenshot = XCTAttachment(screenshot: app.screenshot())
        emptyScreenshot.name = "Centered placeholder and record control"
        emptyScreenshot.lifetime = .keepAlways
        add(emptyScreenshot)
        record.tap()
        XCTAssertFalse(app.buttons["vvterm.composer.stop-recording"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(app.textViews["vvterm.composer.text"].value as? String, "")
        let promptScreenshot = XCTAttachment(screenshot: app.screenshot())
        promptScreenshot.name = "Hold to record prompt"
        promptScreenshot.lifetime = .keepAlways
        add(promptScreenshot)
        // A tap exits the hold prompt and restores normal editing.
        app.textViews["vvterm.composer.text"].tap()
        app.textViews["vvterm.composer.text"].typeText("typed")
        XCTAssertEqual(app.textViews["vvterm.composer.text"].value as? String, "typed")
        app.textViews["vvterm.composer.text"].typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        record.tap()
        let keyboardTop = app.keyboards.firstMatch.frame.minY
        app.textViews["vvterm.composer.text"].press(forDuration: 1.5)
        XCTAssertEqual(app.staticTexts["composer.test.recording-focus"].label, "Recording kept editor")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(app.keyboards.firstMatch.frame.minY, keyboardTop, accuracy: 1)
        let stop = app.buttons["vvterm.composer.stop-recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Lifting the finger must keep recording active")
        XCTAssertEqual(app.textViews["vvterm.composer.text"].value as? String, "")
        stop.tap()
        XCTAssertEqual(app.textViews["vvterm.composer.text"].value as? String, "Voice draft")
        XCTAssertEqual(app.staticTexts["composer.test.bytes"].label, "")
        XCTAssertTrue(app.buttons["vvterm.composer.send"].exists)
    }

    @MainActor
    func testNativeAttachmentMenuKeepsKeyboardAndDismissesWithoutChangingDraft() {
        let app = launch()
        app.buttons["vvterm.composer.toggle"].tap()
        app.buttons["vvterm.composer.attach"].tap()
        let files = app.buttons["vvterm.attachments.files"]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let paste = app.buttons["vvterm.attachments.paste"]
        XCTAssertTrue(paste.isHittable)
        XCTAssertLessThanOrEqual(paste.frame.maxY, app.buttons["vvterm.composer.record"].frame.maxY + 20)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native attachment menu"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.35)).tap()
        XCTAssertFalse(files.exists)
        XCTAssertEqual(app.staticTexts["composer.test.bytes"].label, "")
    }

    @MainActor
    func testComposerIsHiddenUntilConnectedAndKeepsDraftAcrossReconnect() {
        let app = launch()
        app.buttons["Disconnect"].tap()
        app.buttons["vvterm.composer.toggle"].tap()
        let editor = app.textViews["vvterm.composer.text"]
        XCTAssertFalse(editor.exists)
        XCTAssertFalse(app.buttons["vvterm.composer.attach"].exists)
        app.buttons["Reconnect"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("keep this draft")
        app.buttons["Disconnect"].tap()
        XCTAssertFalse(editor.exists)
        app.buttons["Reconnect"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "keep this draft")
        XCTAssertEqual(app.staticTexts["composer.test.bytes"].label, "")
    }

    @MainActor
    func testChatDraftStaysAboveKeyboardAfterAppSwitch() {
        let app = launch()
        app.buttons["vvterm.composer.toggle"].tap()
        let editor = app.textViews["vvterm.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("keep after app switch")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(editor.isHittable)
        XCTAssertLessThanOrEqual(editor.frame.maxY, app.keyboards.firstMatch.frame.minY)
        XCTAssertEqual(editor.value as? String, "keep after app switch")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Chat input bottom spacing"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testRecordingAndProcessingKeepKeyboardPosition() {
        let app = launch()
        app.buttons["vvterm.composer.toggle"].tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let top = keyboard.frame.minY
        app.buttons["composer.test.voice-state"].tap()
        XCTAssertTrue(app.buttons["vvterm.composer.stop-recording"].waitForExistence(timeout: 5))
        XCTAssertTrue(keyboard.exists)
        XCTAssertEqual(keyboard.frame.minY, top, accuracy: 1)
        let recording = XCTAttachment(screenshot: app.screenshot())
        recording.name = "Recording keeps keyboard in place"
        recording.lifetime = .keepAlways
        add(recording)
        app.buttons["composer.test.voice-state"].tap()
        XCTAssertTrue(app.staticTexts["Transcribing audio"].waitForExistence(timeout: 5))
        XCTAssertTrue(keyboard.exists)
        XCTAssertEqual(keyboard.frame.minY, top, accuracy: 1)
        app.buttons["composer.test.voice-state"].tap()
        app.textViews["vvterm.composer.text"].typeText("editable again")
        XCTAssertEqual(app.textViews["vvterm.composer.text"].value as? String, "editable again")
    }

    @MainActor
    func testFindHidesComposerAndDisconnectDismissesKeyboard() {
        let app = launch()
        app.buttons["vvterm.composer.toggle"].tap()
        let editor = app.textViews["vvterm.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("saved draft")
        app.buttons["Find"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: editor)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "saved draft")
        app.buttons["Disconnect"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testHoldOnWaveformRecordsUntilStopWithoutClosingKeyboard() {
        let app = launch()
        app.buttons["vvterm.composer.toggle"].tap()
        let record = app.buttons["vvterm.composer.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        let top = app.keyboards.firstMatch.frame.minY
        record.press(forDuration: 1.5)
        XCTAssertEqual(app.staticTexts["composer.test.recording-focus"].label, "Recording kept editor")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(app.keyboards.firstMatch.frame.minY, top, accuracy: 1)
        let stop = app.buttons["vvterm.composer.stop-recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Lifting the finger must keep recording active")
        XCTAssertEqual(app.textViews["vvterm.composer.text"].value as? String, "")
        stop.tap()
        XCTAssertEqual(app.textViews["vvterm.composer.text"].value as? String, "Voice draft")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(app.keyboards.firstMatch.frame.minY, top, accuracy: 1)
        XCTAssertEqual(app.staticTexts["composer.test.bytes"].label, "")
    }

    @MainActor
    func testUploadProgressStaysOnAttachmentWithStableSendButton() {
        let app = launch(arguments: ["--composer-slow-upload"])
        app.buttons["vvterm.composer.toggle"].tap()
        app.buttons["composer.test.add"].tap()
        let progress = app.activityIndicators["vvterm.attachment.upload.one.png"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        let preview = app.images["vvterm.attachment.preview.one.png"]
        XCTAssertTrue(preview.frame.contains(progress.frame))
        let send = app.buttons["vvterm.composer.send"]
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled)
        XCTAssertFalse(send.frame.intersects(progress.frame))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Upload progress on attachment"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Finish uploads"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
        waitForExpectations(timeout: 8)
        XCTAssertFalse(progress.exists)
        XCTAssertEqual(app.staticTexts["composer.test.sent"].label, "No input sent")
    }

    @MainActor
    func testCameraReturnsToChatAndNormalInput() {
        let app = launch()
        for chat in [false, true] {
            if chat { app.buttons["vvterm.composer.toggle"].tap() }
            let attach = app.buttons[chat ? "vvterm.composer.attach" : "vvterm.keyboard.accessory.attachments"]
            XCTAssertTrue(attach.waitForExistence(timeout: 5))
            attach.tap()
            let camera = app.buttons["vvterm.attachments.camera"]
            XCTAssertTrue(camera.waitForExistence(timeout: 5))
            camera.tap()
            XCTAssertTrue(app.buttons["PhotoCapture"].waitForExistence(timeout: 5))
            app.buttons["DismissImagePickerButton"].tap()
            XCTAssertTrue(attach.waitForExistence(timeout: 5))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["composer.test.sent"].label, "No input sent")
        }
    }

    @MainActor
    func testClosingServerReleasesComposerKeyboard() {
        let app = launch()
        app.buttons["vvterm.composer.toggle"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.textViews["vvterm.composer.text"].exists)
    }

    @MainActor
    private func selectedText(in app: XCUIApplication) -> String {
        let diagnostic = app.staticTexts["composer.test.content"].label
        return diagnostic.components(separatedBy: "selection=").last?
            .components(separatedBy: " terminalInput=").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @MainActor
    private func contentPoint(in app: XCUIApplication, row: Double) throws -> XCUICoordinate {
        app.buttons["Read selection"].tap()
        let diagnostic = app.staticTexts["composer.test.content"].label
        func metric(_ name: String) throws -> Double {
            let token = diagnostic.split(separator: " ").first { $0.hasPrefix(name + "=") }
            return try XCTUnwrap(token?.split(separator: "=").last.flatMap { Double($0) })
        }
        let height = try metric("cellHeight")
        let width = try metric("cellWidth")
        XCTAssertGreaterThan(height, 0)
        return app.otherElements["composer.test.terminal"].coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: width * 5.5, dy: height * row))
    }

    @MainActor
    private func launch(arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--vvterm-ui-test-composer", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", "Dark"] + arguments
        app.launch()
        // Installation can start the regular app before XCUITest supplies its arguments.
        // Restart only when the server list mounted instead of the test harness.
        if !app.buttons["vvterm.composer.toggle"].waitForExistence(timeout: 5),
           app.buttons["vvterm.serverList.settings"].exists {
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(app.buttons["vvterm.composer.toggle"].waitForExistence(timeout: 10))
        return app
    }
}
#endif
