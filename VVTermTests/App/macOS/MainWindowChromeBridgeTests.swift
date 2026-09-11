#if os(macOS)
import AppKit
import XCTest
@testable import VVTerm

@MainActor
final class MainWindowChromeBridgeTests: XCTestCase {
    func testNotificationReusesAnExistingMainWindow() {
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let terminal = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        terminal.isReleasedWhenClosed = false
        defer { settings.close(); terminal.close() }
        terminal.contentView = MainWindowChromeBridge.WindowObserverView()
        XCTAssertFalse(MainWindowChromeBridge.bringMainWindowForward(in: [settings]))
        XCTAssertTrue(MainWindowChromeBridge.bringMainWindowForward(in: [settings, terminal]))
        XCTAssertTrue(terminal.isVisible)
        XCTAssertFalse(settings.isVisible)
    }

    func testWindowChromeDoesNotPaintContentOrFrameLayers() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let observer = MainWindowChromeBridge.WindowObserverView()
        window.contentView = observer
        observer.wantsLayer = true
        let parent = try XCTUnwrap(observer.superview)
        parent.wantsLayer = true
        observer.layer?.backgroundColor = NSColor.red.cgColor
        parent.layer?.backgroundColor = NSColor.blue.cgColor
        observer.applyIfPossible()
        XCTAssertEqual(observer.layer?.backgroundColor, NSColor.red.cgColor)
        XCTAssertEqual(parent.layer?.backgroundColor, NSColor.blue.cgColor)
        XCTAssertEqual(window.backgroundColor, .windowBackgroundColor)
    }
}
#endif
