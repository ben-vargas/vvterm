#if os(macOS)
import AppKit
import Testing
@testable import VVTerm

@MainActor
struct MacSidebarToolbarTests {
    @Test
    func emptyToolbarTracksSidebarBeforeConnection() throws {
        let controller = MacConnectionToolbarController()
        let shell = makeShell()
        let splitView = shell.splitView
        controller.configureSidebar(splitViewController: shell)

        let separator = try #require(controller.toolbar.items.compactMap {
            $0 as? NSTrackingSeparatorToolbarItem
        }.first)
        #expect(separator.splitView === splitView)
        #expect(separator.dividerIndex == 0)
        #expect(controller.toolbar.items.map(\.itemIdentifier) == [
            .flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator,
        ])

        // Toolbar rebuilds must keep the same divider target.
        let replacement = try #require(controller.toolbar(
            controller.toolbar,
            itemForItemIdentifier: .sidebarTrackingSeparator,
            willBeInsertedIntoToolbar: true
        ) as? NSTrackingSeparatorToolbarItem)
        #expect(replacement.splitView === splitView)
        #expect(replacement.dividerIndex == 0)
    }

    @Test
    func hiddenSidebarKeepsToggleVisibleAndRestoresDivider() async throws {
        let controller = MacConnectionToolbarController()
        let shell = makeShell()
        let window = NSWindow(contentViewController: shell)
        window.setContentSize(NSSize(width: 900, height: 600))
        window.toolbarStyle = .unified
        controller.configureSidebar(splitViewController: shell)
        window.toolbar = controller.toolbar
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let sidebar = shell.splitViewItems[0]
        for collapsed in [true, false, true, false] {
            await withCheckedContinuation { continuation in
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    sidebar.animator().isCollapsed = collapsed
                }, completionHandler: {
                    continuation.resume()
                })
            }
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(sidebar.isCollapsed == collapsed)
            #expect(sidebar.viewController.view.visibleRect.isEmpty == collapsed,
                    "Sidebar frame: \(sidebar.viewController.view.frame), visible: \(sidebar.viewController.view.visibleRect), split: \(shell.splitView.frame)")
            let identifiers = controller.toolbar.items.map(\.itemIdentifier)
            #expect(identifiers == [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator])
            #expect(controller.toolbar.visibleItems?.contains {
                $0.itemIdentifier == .toggleSidebar
            } == true)
        }
    }

    private func makeShell() -> NSSplitViewController {
        let shell = NSSplitViewController()
        shell.splitView.isVertical = true
        let sidebar = NSSplitViewItem(sidebarWithViewController: NSViewController())
        sidebar.viewController.view = NSView()
        sidebar.minimumThickness = 200
        sidebar.maximumThickness = 300
        sidebar.canCollapse = true
        let detail = NSViewController()
        detail.view = NSView()
        shell.addSplitViewItem(sidebar)
        shell.addSplitViewItem(NSSplitViewItem(viewController: detail))
        return shell
    }
}
#endif
