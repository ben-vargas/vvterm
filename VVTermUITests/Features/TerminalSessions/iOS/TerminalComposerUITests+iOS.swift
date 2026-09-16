#if os(iOS)
import XCTest
import UIKit

final class TerminalComposerUITests: XCTestCase {
    @MainActor
    func testChatAccessorySendsToTerminalAndPreservesDraft() {
        let app = launch(arguments: ["--composer-accessory", "--vvterm-debug-log=keyboard"])
        app.buttons["vvterm.composer.toggle"].tap()
        let editor = app.textViews["vvterm.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("keep draft")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Chat accessory bar"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tab = app.buttons["vvterm.composer.accessory.system.tab"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        expectation(for: NSPredicate(format: "label == %@", "<TAB>"), evaluatedWith: app.staticTexts["composer.test.bytes"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(editor.value as? String, "keep draft")
        XCTAssertLessThanOrEqual(tab.frame.maxY, editor.frame.minY)
        for id in ["modifier.ctrl", "modifier.alt", "modifier.shift", "system.commandModifier"] {
            XCTAssertFalse(app.buttons["vvterm.composer.accessory.\(id)"].exists)
        }
        for id in ["voice", "attachments", "hide"] {
            XCTAssertFalse(app.buttons["vvterm.keyboard.accessory.\(id)"].exists)
        }
        app.otherElements["composer.test.terminal"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(tab.isHittable)
        XCTAssertLessThanOrEqual(tab.frame.maxY, editor.frame.minY)
        tab.tap()
        expectation(for: NSPredicate(format: "label == %@", "<TAB><TAB>"), evaluatedWith: app.staticTexts["composer.test.bytes"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        editor.tap()
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "keep draft")
        app.scrollViews["vvterm.composer.accessory.keys"].swipeLeft()
        let scrolledShot = XCTAttachment(screenshot: app.screenshot())
        scrolledShot.name = "Chat accessory scrolled edges"
        scrolledShot.lifetime = .keepAlways
        add(scrolledShot)
        app.buttons["vvterm.composer.toggle"].tap()
        // Normal mode preserves an explicit keyboard dismissal. Open it through its command.
        if !app.buttons["vvterm.keyboard.accessory.system.tab"].exists {
            app.buttons["composer.test.menu"].tap()
            app.buttons["Keyboard"].tap()
        }
        XCTAssertTrue(app.buttons["vvterm.keyboard.accessory.system.tab"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["vvterm.keyboard.accessory.hide"].exists)
        XCTAssertTrue(app.buttons["vvterm.keyboard.accessory.attachments"].exists)
        XCTAssertFalse(tab.exists)
        let normalShot = XCTAttachment(screenshot: app.screenshot())
        normalShot.name = "Normal capsule accessory"
        normalShot.lifetime = .keepAlways
        add(normalShot)
    }

    @MainActor
    func testChatAccessoryFadesAtPaneEdges() {
        let app = launch(arguments: ["--composer-accessory"])
        app.buttons["vvterm.composer.toggle"].tap()
        let row = app.scrollViews["vvterm.composer.accessory.keys"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let terminal = app.otherElements["composer.test.terminal"]
        XCTAssertEqual(row.frame.minX, terminal.frame.minX, accuracy: 1)
        XCTAssertEqual(row.frame.maxX, terminal.frame.maxX, accuracy: 1)
        row.swipeLeft()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Pane edge accessory fade"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testInputModePreviewRespondsToKeysAndSend() {
        let app = launch()
        app.buttons["composer.test.settings"].tap()
        app.buttons["Input Mode"].tap()
        let output = app.staticTexts["vvterm.settings.inputMode.preview.output"]
        let ctrl = app.buttons["vvterm.keyboard.accessory.modifier.ctrl"]
        XCTAssertTrue(ctrl.waitForExistence(timeout: 5))
        ctrl.tap()
        let row = app.scrollViews["vvterm.keyboard.accessory.keys"]
        row.swipeLeft()
        let tab = app.buttons["vvterm.keyboard.accessory.system.tab"]
        // Move back if the full swipe passed Tab on a narrow device.
        if !tab.isHittable { row.swipeRight() }
        if !tab.isHittable { row.swipeLeft(velocity: .slow) }
        tab.tap()
        XCTAssertEqual(output.label, "Ctrl+Tab")
        XCTAssertFalse(ctrl.isSelected)
        let normalShot = XCTAttachment(screenshot: app.screenshot())
        normalShot.name = "Normal interactive preview"
        normalShot.lifetime = .keepAlways
        add(normalShot)
        app.segmentedControls["vvterm.input-mode"].buttons["Chat Mode"].tap()
        let accessory = app.switches["vvterm.chat.accessory"]
        accessory.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["vvterm.composer.accessory.system.tab"].tap()
        XCTAssertEqual(output.label, "Tab")
        app.buttons["vvterm.settings.inputMode.preview.send"].tap()
        XCTAssertEqual(output.label, "server:~ $ ls -la")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let draft = app.textFields["vvterm.settings.inputMode.preview.draft"]
        draft.tap()
        draft.typeText("sample")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["vvterm.settings.inputMode.preview.done"].exists)
        draft.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        output.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "sample")
        draft.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["vvterm.settings.inputMode.preview.send"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(output.label, "server:~ $ sample")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Interactive input preview"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testAttachmentMenuPastesTextIntoChatAndNormalInput() {
        let app = launch(arguments: ["--composer-clipboard-text"])
        app.buttons["vvterm.composer.toggle"].tap()
        let editor = app.textViews["vvterm.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("draft ")
        app.buttons["vvterm.composer.attach"].tap()
        app.buttons["vvterm.attachments.paste"].tap()
        expectation(for: NSPredicate(format: "value == %@", "draft clipboard text"), evaluatedWith: editor)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.staticTexts["composer.test.bytes"].label, "")
        XCTAssertFalse(app.staticTexts["vvterm.composer.error"].exists)
        app.buttons["vvterm.composer.toggle"].tap()
        app.buttons["vvterm.keyboard.accessory.attachments"].tap()
        app.buttons["vvterm.attachments.paste"].tap()
        expectation(for: NSPredicate(format: "label == %@", "clipboard text"), evaluatedWith: app.staticTexts["composer.test.bytes"])
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testDisabledVoiceInputHidesMicrophoneAndRestoresTyping() {
        let app = launch()
        app.buttons["vvterm.composer.toggle"].tap()
        let record = app.buttons["vvterm.composer.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        app.buttons["composer.test.voice-availability"].tap()
        XCTAssertFalse(record.exists)
        let editor = app.textViews["vvterm.composer.text"]
        editor.tap()
        editor.typeText("text")
        XCTAssertEqual(editor.value as? String, "text")
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        XCTAssertFalse(record.exists)
        app.buttons["composer.test.voice-availability"].tap()
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.press(forDuration: 1)
        XCTAssertTrue(app.buttons["vvterm.composer.stop-recording"].exists)
        app.buttons["composer.test.voice-availability"].tap()
        XCTAssertFalse(app.buttons["vvterm.composer.stop-recording"].exists)
        XCTAssertFalse(record.exists)
    }

    @MainActor
    func testChatKeyboardOptionsPersistAndCommandsStayLiteral() {
        let app = launch()
        app.buttons["composer.test.settings"].tap()
        app.buttons["Input Mode"].tap()
        XCTAssertTrue(app.switches["vvterm.composer.keyboard-option.1"].exists)
        let correction = app.switches["vvterm.composer.keyboard-option.1"]
        XCTAssertEqual(correction.value as? String, "0")
        correction.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(correction.value as? String, "1")
        app.segmentedControls["vvterm.input-mode"].buttons["Chat Mode"].tap()
        XCTAssertEqual(correction.value as? String, "1")
        app.navigationBars["Input Mode"].buttons["BackButton"].tap()
        app.buttons["Input Mode"].tap()
        XCTAssertEqual(correction.value as? String, "1")
        correction.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.navigationBars["Input Mode"].buttons["BackButton"].tap()
        app.buttons["Done"].tap()
        let editor = app.textViews["vvterm.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let command = "git chekc --name='a--b' "
        editor.typeText(command)
        XCTAssertEqual(editor.value as? String, command)
    }

    @MainActor
    func testTextStepsAppendToDraftAndSendInOrder() {
        let app = launch(arguments: ["--composer-text-fixture"])
        app.buttons["vvterm.composer.toggle"].tap()
        let editor = app.textViews["vvterm.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("draft")
        app.buttons["vvterm.composer.send"].tap()
        expectation(for: NSPredicate(format: "label == %@", "Review: draft briefly<CR>"), evaluatedWith: app.staticTexts["composer.test.bytes"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(editor.value as? String, "")
        editor.typeText("next")
        XCTAssertEqual(editor.value as? String, "next")
    }

    @MainActor
    func testSendSettingsAreChatOnlyAndTextStepsUseCommandEditor() {
        let app = launch()
        app.buttons["composer.test.settings"].tap()
        app.buttons["Input Mode"].tap()
        XCTAssertFalse(app.buttons["Customize Send Action"].exists)
        XCTAssertFalse(app.switches["vvterm.chat.accessory"].exists)
        app.segmentedControls["vvterm.input-mode"].buttons["Chat Mode"].tap()
        let accessory = app.switches["vvterm.chat.accessory"]
        XCTAssertEqual(accessory.value as? String, "0")
        accessory.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(accessory.value as? String, "1")
        let previewShot = XCTAttachment(screenshot: app.screenshot())
        previewShot.name = "Chat accessory settings preview"
        previewShot.lifetime = .keepAlways
        add(previewShot)
        app.buttons["Customize Send Action"].tap()
        app.buttons["vvterm.composer.add-action"].tap()
        app.textFields["vvterm.composer.action-name"].tap()
        app.textFields["vvterm.composer.action-name"].typeText("Saved prompt")
        app.buttons["vvterm.composer.add-step"].tap()
        XCTAssertFalse(app.buttons["Prompt"].exists)
        app.buttons["Text"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'vvterm.composer.step.' AND label BEGINSWITH 'Text'")).firstMatch.tap()
        let text = app.textViews["vvterm.composer.step-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap()
        text.typeText("Review this code.\n")
        XCTAssertEqual(text.value as? String, "Review this code.\n")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Saved text step editor"
        shot.lifetime = .keepAlways
        add(shot)
        app.navigationBars["Text"].buttons["BackButton"].tap()
        app.buttons["vvterm.composer.save-action"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Saved prompt'")).firstMatch.waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Saved prompt'")).firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'vvterm.composer.step.' AND label BEGINSWITH 'Text'")).firstMatch.tap()
        XCTAssertEqual(text.value as? String, "Review this code.\n")
        app.navigationBars["Text"].buttons["BackButton"].tap()
        app.buttons["vvterm.composer.save-action"].tap()
        app.navigationBars["Customize Send Action"].buttons["BackButton"].tap()
        app.segmentedControls["vvterm.input-mode"].buttons["Normal Mode"].tap()
        XCTAssertFalse(app.buttons["Customize Send Action"].exists)
    }

    @MainActor
    func testEmptySendAndHoldMenuKeepChatFocus() {
        let app = launch()
        app.buttons["vvterm.composer.toggle"].tap()
        let send = app.buttons["vvterm.composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)
        let record = app.buttons["vvterm.composer.record"]
        XCTAssertGreaterThan(record.frame.minX, send.frame.maxX)
        XCTAssertEqual(record.frame.width, 40, accuracy: 1)
        XCTAssertEqual(record.frame.midY, app.buttons["vvterm.composer.attach"].frame.midY, accuracy: 1)
        let layout = XCTAttachment(screenshot: app.screenshot())
        layout.name = "Separate microphone button"
        layout.lifetime = .keepAlways
        add(layout)
        send.tap()
        let bytes = app.staticTexts["composer.test.bytes"]
        expectation(for: NSPredicate(format: "label == %@", "<CR>"), evaluatedWith: bytes)
        waitForExpectations(timeout: 5)
        send.press(forDuration: 0.7)
        app.buttons["vvterm.composer.action.704D03A6-3602-462F-8DF1-1A7D2A0EE003"].tap()
        expectation(for: NSPredicate(format: "label == %@", "<CR><TAB>"), evaluatedWith: bytes)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let editor = app.textViews["vvterm.composer.text"]
        editor.typeText("insert")
        XCTAssertFalse(record.exists)
        send.press(forDuration: 0.7)
        app.buttons["vvterm.composer.action.704D03A6-3602-462F-8DF1-1A7D2A0EE002"].tap()
        expectation(for: NSPredicate(format: "label == %@", "<CR><TAB>insert"), evaluatedWith: bytes)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(editor.value as? String, "")
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        editor.typeText("queue")
        send.press(forDuration: 0.7)
        app.buttons["vvterm.composer.action.704D03A6-3602-462F-8DF1-1A7D2A0EE003"].tap()
        expectation(for: NSPredicate(format: "label == %@", "<CR><TAB>insertqueue<TAB>"), evaluatedWith: bytes)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        add(XCTAttachment(screenshot: app.screenshot()))
    }

    @MainActor
    func testCustomSequenceCanBecomePrimaryAndSurvivesRelaunch() {
        var app = launch()
        app.buttons["composer.test.settings"].tap()
        app.buttons["Input Mode"].tap()
        XCTAssertFalse(app.buttons["Customize Send Action"].exists)
        app.segmentedControls["vvterm.input-mode"].buttons["Chat Mode"].tap()
        app.buttons["Customize Send Action"].tap()
        app.buttons["vvterm.composer.add-action"].tap()
        let name = app.textFields["vvterm.composer.action-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Double Enter")
        app.buttons["vvterm.composer.add-step"].tap()
        app.buttons["Shortcut"].tap()
        app.buttons["vvterm.composer.save-action"].tap()
        app.buttons["vvterm.composer.primary-action"].tap()
        app.buttons["Double Enter"].tap()
        add(XCTAttachment(screenshot: app.screenshot()))
        app.terminate()
        app = launch(arguments: ["--preserve-composer-actions"])
        app.buttons["vvterm.composer.toggle"].tap()
        let send = app.buttons["vvterm.composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertEqual(send.value as? String, "Double Enter")
        app.textViews["vvterm.composer.text"].typeText("twice")
        send.tap()
        let bytes = app.staticTexts["composer.test.bytes"]
        expectation(for: NSPredicate(format: "label == %@", "twice<CR><CR>"), evaluatedWith: bytes)
        waitForExpectations(timeout: 5)
        send.tap()
        expectation(for: NSPredicate(format: "label == %@", "twice<CR><CR><CR><CR>"), evaluatedWith: bytes)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
    }

    @MainActor
    func testGalleryVideoUsesChatDraftAndNormalImmediateSending() throws {
        // Seed a short video and a photo with simctl addmedia, then enable this in the test runner.
        guard ProcessInfo.processInfo.environment["VVTERM_UI_TEST_GALLERY"] == "1" else {
            throw XCTSkip("Requires simulator Photos fixtures and VVTERM_UI_TEST_GALLERY=1")
        }
        let app = launch()
        for chat in [true, false] {
            app.buttons["vvterm.composer.toggle"].tap()
            let attachID = chat ? "vvterm.composer.attach" : "vvterm.keyboard.accessory.attachments"
            XCTAssertTrue(app.buttons[attachID].waitForExistence(timeout: 5))
            app.buttons[attachID].tap()
            app.buttons["vvterm.attachments.photos"].tap()
            let video = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Video,'")).firstMatch
            XCTAssertTrue(video.waitForExistence(timeout: 10), app.debugDescription)
            video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'")).firstMatch
            XCTAssertTrue(photo.exists, app.debugDescription)
            // Photos can report an invalid accessibility activation point for an edge tile.
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            app.buttons["Add"].tap()
            let sent = app.staticTexts["composer.test.sent"]
            if chat {
                let removals = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'vvterm.attachment.remove.'"))
                expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: removals)
                waitForExpectations(timeout: 10)
                XCTAssertEqual(sent.label, "No input sent")
                let send = app.buttons["vvterm.composer.send"]
                expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
                waitForExpectations(timeout: 10)
                add(XCTAttachment(screenshot: app.screenshot()))
                send.tap()
            } else {
                XCTAssertFalse(app.textViews["vvterm.composer.text"].exists)
            }
            let bytes = app.staticTexts["composer.test.bytes"]
            expectation(for: NSPredicate(format: "label CONTAINS %@", chat ? "<CR>" : "<CR>/tmp/"), evaluatedWith: bytes)
            waitForExpectations(timeout: 10)
            let names = sent.label.components(separatedBy: " /tmp/")
            XCTAssertEqual(names.count, 2)
            XCTAssertTrue(names[0].lowercased().hasSuffix(".mp4"), sent.label)
            XCTAssertTrue(names[1].lowercased().hasSuffix(".png"), sent.label)
            XCTAssertEqual(bytes.label.filter { $0 == "<" }.count, 1, "Only Chat Send must press Enter")
        }
    }

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
            XCTAssertEqual(selectedText(in: app), "two", app.staticTexts["composer.test.content"].label)
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
            XCTAssertEqual(selectedText(in: app), "two", app.staticTexts["composer.test.content"].label)
        }
    }

    @MainActor
    func testControlCenterPreservesChatDraftAndKeyboard() {
        let app = launch()
        app.buttons["vvterm.composer.toggle"].tap()
        let editor = app.textViews["vvterm.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("before")
        let frame = editor.frame
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.01))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.65)))
        XCTAssertTrue(springboard.otherElements["cc-root-folder-view"].waitForExistence(timeout: 5), springboard.debugDescription)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.frame.minY, frame.minY, accuracy: 1)
        XCTAssertEqual(editor.value as? String, "before")
        editor.typeText(" after")
        XCTAssertEqual(editor.value as? String, "before after")
        XCTAssertEqual(app.staticTexts["composer.test.bytes"].label, "")
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
    func testNativeIPadDismissKeepsChatDraftAndRestoresOnTap() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Native dismiss button requires iPad") }
        let app = launch()
        app.buttons["vvterm.composer.toggle"].tap()
        let editor = app.textViews["vvterm.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("keep draft")
        let keyboard = app.keyboards.firstMatch
        if keyboard.frame.width < app.frame.width * 0.8 {
            keyboard.pinch(withScale: 3, velocity: 2)
        }
        let dismiss = keyboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label ==[c] %@", "Hide keyboard")).firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), app.debugDescription)
        dismiss.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        // A scene round trip must preserve native dismissal and the draft.
        sleep(2)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "keep draft")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText(" again")
        XCTAssertEqual(editor.value as? String, "keep draft again")
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
        XCTAssertLessThanOrEqual(app.frame.maxY - app.buttons["vvterm.composer.send"].frame.maxY, 21)
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
        XCTAssertTrue(app.staticTexts["Review text and attachments before sending. Choose what the Send button does."].exists)
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
        XCTAssertTrue(app.buttons["vvterm.composer.send"].exists)
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
        XCTAssertFalse(record.exists)
        app.textViews["vvterm.composer.text"].typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        let keyboardTop = app.keyboards.firstMatch.frame.minY
        record.press(forDuration: 1.5)
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
        XCUIDevice.shared.orientation = .portrait
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
