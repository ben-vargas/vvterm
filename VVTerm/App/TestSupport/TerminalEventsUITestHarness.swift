#if DEBUG
import SwiftUI
import Combine
import UserNotifications

/// A real libghostty output path with no remote server or native notifications.
@MainActor
final class TerminalEventsUITestHarnessModel: ObservableObject {
    @Published private(set) var terminals: [GhosttyTerminalView] = []
    @Published private(set) var notificationCount = 0
    @Published private(set) var lastNotification = ""
    @Published private(set) var geometry = ""
    let paneIds: [UUID]
    let notificationNavigation: TerminalNotificationNavigationStore
    let server: Server
    private let sourceTab: TerminalTab
    private let otherTab: TerminalTab
    private var lastNotificationContext: TerminalNotificationContext?
    let tabManager: TerminalTabManager
    private var outputTask: Task<Void, Never>?
    // The runtime holds its notification client. Use a separate forwarding client
    // with a weak reference so this model can tear down without a retain cycle.
    private(set) var runtime: GhosttyRuntime?

    init(tabManager: TerminalTabManager) {
        self.tabManager = tabManager
        let server = Server(workspaceId: UUID(), name: "Events", host: "example.invalid", username: "test")
        self.server = server
        let panes = [UUID(), UUID()]
        paneIds = panes
        sourceTab = TerminalTab(
            serverId: server.id, title: "Source", rootPaneId: panes[0],
            layout: .split(.init(direction: .horizontal, ratio: 0.5,
                                 left: .leaf(paneId: panes[0]), right: .leaf(paneId: panes[1])))
        )
        otherTab = TerminalTab(serverId: server.id, title: "Other")
        notificationNavigation = TerminalNotificationNavigationStore(
            tabManager: tabManager, serverProvider: { $0 == server.id ? server : nil },
            unlockServer: { _ in true }
        )
    }

    var serverId: UUID { server.id }
    var sourceTabId: UUID { sourceTab.id }
    var focusedPaneIndex: Int? {
        guard let pane = tabManager.sessionState.tab(id: sourceTab.id, for: server.id)?.focusedPaneId else { return nil }
        return paneIds.firstIndex(of: pane)
    }

    func selectOtherTab() {
        tabManager.sessionState.selectTab(otherTab.id, for: server.id)
        tabManager.sessionState.selectView(.files, for: server.id)
    }

    func closeSourceTab() {
        _ = tabManager.sessionState.removeTab(sourceTab)
    }

    func openLastNotification() {
        guard let context = lastNotificationContext else { return }
        let request = NativeTerminalNotificationClient.request(.init(title: "Test", body: "Ready"), context: context)
        if let destination = NativeTerminalNotificationClient.openContext(
            actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: request.content.userInfo
        ) { notificationNavigation.request(destination) }
    }

    var progress: TerminalProgressStore { tabManager.presentationState.progress }

    var presentationStatus: String {
        #if os(iOS)
        return terminals.enumerated().map { index, terminal in
            let ready = terminal.panePresentationOwner != nil && !terminal.isRenderingPaused && terminal.acceptsTerminalInput
            return "\(index == 0 ? "A" : "B")=\(ready ? "ready" : "paused")"
        }.joined(separator: " ")
        #else
        return ""
        #endif
    }

    func start() {
        guard runtime == nil else { return }
        let client = HarnessNotificationClient(owner: self)
        let runtime = GhosttyRuntime(configuration: .defaultValue, notificationClient: client)
        self.runtime = runtime
        guard runtime.app != nil else { return }
        for pane in paneIds {
            tabManager.sessionState.install(sourceTab, paneState: TerminalPaneState(
                paneId: pane, tabId: sourceTab.id, serverId: server.id
            ), select: true)
        }
        tabManager.sessionState.install(otherTab, paneState: TerminalPaneState(
            paneId: otherTab.rootPaneId, tabId: otherTab.id, serverId: server.id
        ), select: false)
        terminals = paneIds.map { makeTerminal(paneId: $0, runtime: runtime) }
    }

    func stop() {
        outputTask?.cancel()
        outputTask = nil
        for (index, terminal) in terminals.enumerated() {
            tabManager.unregisterTerminalSurface(terminal, for: paneIds[index])
        }
        terminals = []
        _ = tabManager.sessionState.removeTab(sourceTab)
        _ = tabManager.sessionState.removeTab(otherTab)
        runtime?.cleanup()
        runtime = nil
    }

    func replace(_ index: Int) {
        guard terminals.indices.contains(index), let runtime else { return }
        outputTask?.cancel()
        let old = terminals[index]
        terminals[index] = makeTerminal(paneId: paneIds[index], runtime: runtime)
        tabManager.unregisterTerminalSurface(old, for: paneIds[index])
    }

    func send(_ sequence: String, to index: Int) {
        guard terminals.indices.contains(index) else { return }
        let terminal = terminals[index]
        outputTask?.cancel()
        outputTask = Task { [weak self, weak terminal] in
            guard let terminal else { return }
            _ = await terminal.receiveTerminalOutput(Data(sequence.utf8))
            guard !Task.isCancelled else { return }
            self?.runtime?.appTick()
            if let size = terminal.terminalGeometry {
                self?.geometry = "\(size.columns)x\(size.rows)"
            }
        }
    }

    func post(_ content: TerminalNotificationContent, context: TerminalNotificationContext) {
        lastNotificationContext = context
        notificationCount += 1
        lastNotification = content.title + ": " + content.body
    }

    private func makeTerminal(paneId: UUID, runtime: GhosttyRuntime) -> GhosttyTerminalView {
        #if os(iOS)
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300), worktreePath: NSHomeDirectory(),
            ghosttyApp: runtime.app!, appWrapper: runtime, paneId: paneId.uuidString,
            terminalAccessoryInputSnapshot: .init(profile: .defaultValue(lastWriterDeviceId: "terminal-events-ui-test"), showsDismissKeyboardButton: true),
            useCustomIO: true
        )
        #else
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300), worktreePath: NSHomeDirectory(),
            ghosttyApp: runtime.app!, appWrapper: runtime, paneId: paneId.uuidString, useCustomIO: true
        )
        #endif
        tabManager.registerTerminalSurface(terminal, for: paneId)
        return terminal
    }

    private final class HarnessNotificationClient: TerminalNotificationSending {
        weak var owner: TerminalEventsUITestHarnessModel?
        init(owner: TerminalEventsUITestHarnessModel) { self.owner = owner }
        func authorization() async -> TerminalNotificationAuthorization { .denied }
        func requestAuthorization() async -> TerminalNotificationAuthorization { .denied }
        func post(_ content: TerminalNotificationContent, context: TerminalNotificationContext) {
            owner?.post(content, context: context)
        }
    }
}

struct TerminalEventsUITestHarness: View {
    @StateObject private var model: TerminalEventsUITestHarnessModel
    @State private var selectedPane = 0
    @State private var openedDestination: String?
    @ObservedObject private var sessions: TerminalSessionStateStore

    init(tabManager: TerminalTabManager) {
        _model = StateObject(wrappedValue: TerminalEventsUITestHarnessModel(tabManager: tabManager))
        _sessions = ObservedObject(wrappedValue: tabManager.sessionState)
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("Pane", selection: $selectedPane) {
                Text("A").tag(0)
                Text("B").tag(1)
            }
            .pickerStyle(.segmented)
            HStack {
                eventButton("50%", id: "half", sequence: "9;4;1;50")
                eventButton("Pause", id: "pause", sequence: "9;4;4;50")
                eventButton("Error", id: "error", sequence: "9;4;2;50")
                eventButton("Busy", id: "busy", sequence: "9;4;3")
            }
            HStack {
                eventButton("Remove", id: "remove", sequence: "9;4;0")
                Button("Replace") { model.replace(selectedPane) }
                    .accessibilityIdentifier("events.replace")
                eventButton("Notify", id: "notify", sequence: "777;notify;Test;Ready")
            }
            Text("notifications=\(model.notificationCount) \(model.lastNotification) geometry=\(model.geometry) \(model.presentationStatus)")
                .accessibilityIdentifier("events.diagnostics")
                .font(.caption)
            HStack {
                Button("Other tab") { model.selectOtherTab(); openedDestination = nil }
                    .accessibilityIdentifier("events.other-tab")
                Button("Close source") { model.closeSourceTab() }
                    .accessibilityIdentifier("events.close-source")
                Button("Open notification") { model.openLastNotification() }
                    .accessibilityIdentifier("events.open-notification")
            }
            if let openedDestination {
                Text(openedDestination)
                    .accessibilityIdentifier("events.notification-destination")
            }
            Group {
                if sessions.selectedTabId(for: model.serverId) == model.sourceTabId {
                    HStack(spacing: 4) {
                        ForEach(Array(model.terminals.enumerated()), id: \.element) { index, terminal in
                            ZStack(alignment: .top) {
                                #if os(iOS)
                                TerminalEventsSurface(model: model, index: index, isActive: selectedPane == index)
                                #else
                                TerminalEventsSurface(terminal: terminal)
                                #endif
                                TerminalProgressOverlay(store: model.progress, paneId: model.paneIds[index])
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("events.pane.\(index)")
                        }
                    }
                } else {
                    Text("Other terminal tab")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("events.other-tab-content")
                }
            }
            #if os(iOS)
            // Match ConnectionTabsView's protection for Metal view insertion.
            // Child progress motion must work while container animations are off.
            .transaction { $0.animation = nil }
            #endif
        }
        .padding(8)
        .modifier(TerminalNotificationNavigationModifier { server in
            if server != nil {
                selectedPane = model.focusedPaneIndex ?? 0
                openedDestination = "Source tab, pane \(selectedPane == 0 ? "A" : "B")"
            } else {
                openedDestination = "App"
            }
        })
        .environmentObject(model.notificationNavigation)
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    private func eventButton(_ title: String, id: String, sequence: String) -> some View {
        Button(title) { model.send("\u{1B}]\(sequence)\u{1B}\\", to: selectedPane) }
            .accessibilityIdentifier("events.\(id)")
    }
}

#if os(iOS)
private struct TerminalEventsSurface: View {
    let model: TerminalEventsUITestHarnessModel
    let index: Int
    let isActive: Bool

    var body: some View {
        GeometryReader { geometry in
            if let runtime = model.runtime {
                // Exercise the retained terminal's real SwiftUI host lifecycle.
                RemoteTerminalPaneRepresentable(
                    paneId: model.paneIds[index], server: model.server,
                    credentials: .init(serverId: model.server.id), tabManager: model.tabManager,
                    size: geometry.size, isActive: isActive,
                    terminalContextMenuActions: .init(focus: {}, splitRight: {}, splitLeft: {}, splitDown: {}, splitUp: {}, currentTitle: { "" }, setTitle: { _ in }),
                    onPaneKeyboardShortcut: { _ in }, onProcessExit: {}, onReady: {}, onOpenLink: { _ in },
                    terminalAccessoryInputSnapshot: .init(profile: .defaultValue(lastWriterDeviceId: "events-test"), showsDismissKeyboardButton: true),
                    showsVoiceAccessoryButton: false, onVoiceTrigger: nil
                )
                .environmentObject(runtime)
            }
        }
    }
}
#else
private struct TerminalEventsSurface: NSViewRepresentable {
    let terminal: GhosttyTerminalView
    func makeNSView(context: Context) -> GhosttyTerminalView { terminal }
    func updateNSView(_ view: GhosttyTerminalView, context: Context) {}
}
#endif
#endif
