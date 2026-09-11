import CoreGraphics
import Foundation
import Testing
import UserNotifications
@testable import VVTerm

@MainActor
private final class NotificationSpy: TerminalNotificationSending {
    var events: [(TerminalNotificationContent, TerminalNotificationContext)] = []
    var permissionRequests = 0
    func authorization() async -> TerminalNotificationAuthorization { .denied }
    func requestAuthorization() async -> TerminalNotificationAuthorization {
        permissionRequests += 1
        return .denied
    }
    func post(_ content: TerminalNotificationContent, context: TerminalNotificationContext) {
        events.append((content, context))
    }
}

@Suite(.serialized)
@MainActor
struct GhosttyTerminalEventsTests {
    @Test
    func notificationCopiesBoundedTextBeforeCallbackReturns() {
        var title = Array(repeating: CChar(65), count: 1000) + [0]
        var body = Array(repeating: CChar(66), count: 5000) + [0]
        let content = title.withUnsafeBufferPointer { titleBuffer in
            body.withUnsafeBufferPointer { bodyBuffer in
                GhosttyRuntime.notificationContent(ghostty_action_desktop_notification_s(
                    title: titleBuffer.baseAddress, body: bodyBuffer.baseAddress
                ))
            }
        }
        title[0] = 0
        body[0] = 0
        let unicode = TerminalNotificationContent(title: String(repeating: "😀", count: 200), body: String(repeating: "界", count: 2000))
        #expect(unicode.title.utf8.count <= 256)
        #expect(unicode.body.utf8.count <= 4096)
        #expect(content.title == String(repeating: "A", count: 256))
        #expect(content.body == String(repeating: "B", count: 4096))
        #expect(GhosttyRuntime.notificationContent(.init(title: nil, body: nil)) == .init(title: "", body: ""))
    }

    @Test
    func nativeNotificationUsesPlainTextAndLocalPaneContext() {
        let context = TerminalNotificationContext(paneId: UUID(), tabId: UUID(), serverId: UUID())
        let content = TerminalNotificationContent(title: "", body: "<b>https://example.invalid</b>")
        let request = NativeTerminalNotificationClient.request(content, context: context)
        #expect(request.content.title == "VVTerm")
        #expect(request.content.body == content.body)
        #expect(request.content.attachments.isEmpty)
        #expect(request.content.categoryIdentifier.isEmpty)
        #expect(request.content.threadIdentifier == context.paneId.uuidString)
        #expect(request.content.userInfo["paneId"] as? String == context.paneId.uuidString)
        #expect(request.trigger == nil)
    }

    @Test
    func nativeNotificationTapRequiresCompleteLocalContext() {
        let context = TerminalNotificationContext(paneId: UUID(), tabId: UUID(), serverId: UUID())
        let request = NativeTerminalNotificationClient.request(.init(title: "Test", body: "Done"), context: context)
        let info = request.content.userInfo
        #expect(NativeTerminalNotificationClient.openContext(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: info) == context)
        #expect(NativeTerminalNotificationClient.openContext(actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: info) == nil)
        for invalid in [[:], ["paneId": "invalid"], ["paneId": context.paneId.uuidString, "tabId": context.tabId.uuidString]] as [[AnyHashable: Any]] {
            #expect(NativeTerminalNotificationClient.openContext(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: invalid) == nil)
        }
    }

    @Test
    func realOSCBytesReachPaneStateAndNotificationClient() async throws {
        let notifications = NotificationSpy()
        let runtime = GhosttyRuntime(configuration: .defaultValue, notificationClient: notifications)
        defer { runtime.cleanup() }
        let manager = TerminalTestComposition.makeManager()
        let pane = UUID()
        let terminal = try makeTerminal(runtime)
        defer { manager.unregisterTerminalSurface(terminal, for: pane) }
        manager.registerTerminalSurface(terminal, for: pane)
        let context = TerminalNotificationContext(paneId: pane, tabId: UUID(), serverId: UUID())
        terminal.terminalNotificationContext = context

        // A split escape sequence exercises libghostty's streaming parser.
        #expect(await terminal.receiveTerminalOutput(Data("\u{1B}]9;4;1;".utf8)))
        #expect(await terminal.receiveTerminalOutput(Data("50\u{7}".utf8)))
        try await wait(runtime) { manager.presentationState.progress.states[pane] == .determinate(50) }
        for (sequence, expected) in [
            ("4;20", TerminalProgress.paused(20)),
            ("2;30", .error(30)),
            ("3", .indeterminate)
        ] {
            #expect(await terminal.receiveTerminalOutput(Data("\u{1B}]9;4;\(sequence)\u{1B}\\".utf8)))
            try await wait(runtime) { manager.presentationState.progress.states[pane] == expected }
        }
        #expect(await terminal.receiveTerminalOutput(Data("\u{1B}]9;4;0\u{7}".utf8)))
        try await wait(runtime) { manager.presentationState.progress.states[pane] == nil }
        #expect(await terminal.receiveTerminalOutput(Data("\u{1B}]9;Build finished\u{7}".utf8)))
        try await wait(runtime) { notifications.events.count == 1 }
        // libghostty limits native notification actions to one per second.
        try await Task.sleep(for: .milliseconds(1100))
        #expect(await terminal.receiveTerminalOutput(Data("\u{1B}]777;notify;Build;Done\u{1B}\\".utf8)))
        try await wait(runtime) { notifications.events.count == 2 }
        #expect(notifications.events[0].0 == .init(title: "", body: "Build finished"))
        #expect(notifications.events[1].0 == .init(title: "Build", body: "Done"))
        #expect(notifications.events.allSatisfy { $0.1 == context })
        #expect(notifications.permissionRequests == 0)
    }

    @Test
    func replacementRejectsOldPaneEventsAndClearsProgress() async throws {
        let notifications = NotificationSpy()
        let runtime = GhosttyRuntime(configuration: .defaultValue, notificationClient: notifications)
        defer { runtime.cleanup() }
        let manager = TerminalTestComposition.makeManager()
        let pane = UUID()
        let old = try makeTerminal(runtime)
        defer { old.cleanup() }
        manager.registerTerminalSurface(old, for: pane)
        old.terminalNotificationContext = .init(paneId: pane, tabId: UUID(), serverId: UUID())
        let staleHandler = old.onProgressReport
        old.onProgressReport?(.set, 50)
        #expect(manager.presentationState.progress.states[pane] == .determinate(50))
        let replacement = try makeTerminal(runtime)
        defer { manager.unregisterTerminalSurface(replacement, for: pane) }
        manager.registerTerminalSurface(replacement, for: pane)
        #expect(manager.presentationState.progress.states[pane] == nil)
        #expect(old.terminalNotificationContext == nil)
        staleHandler?(.set, 90)
        #expect(manager.presentationState.progress.states[pane] == nil)
        manager.unregisterTerminalSurface(old, for: pane)
        replacement.onProgressReport?(.set, 25)
        #expect(manager.presentationState.progress.states[pane] == .determinate(25))
    }

    private func makeTerminal(_ runtime: GhosttyRuntime) throws -> GhosttyTerminalView {
        let handle = try #require(runtime.app)
        #if os(iOS)
        return GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300), worktreePath: NSHomeDirectory(),
            ghosttyApp: handle, appWrapper: runtime,
            terminalAccessoryInputSnapshot: .init(profile: .defaultValue(lastWriterDeviceId: "events-test"), showsDismissKeyboardButton: true),
            useCustomIO: true
        )
        #else
        return GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300), worktreePath: NSHomeDirectory(),
            ghosttyApp: handle, appWrapper: runtime, useCustomIO: true
        )
        #endif
    }

    private func wait(_ runtime: GhosttyRuntime, sourceLocation: SourceLocation = #_sourceLocation, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            runtime.appTick()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }
}
