#if os(iOS)
import SwiftUI
import UIKit

/// Keeps both SwiftUI roots in native columns while UIKit adapts to window width.
struct AdaptiveServerNavigation<Sidebar: View, Detail: View>: UIViewControllerRepresentable {
    let hasSelection: Bool
    let sidebar: (@escaping () -> Void) -> Sidebar
    let detail: (@escaping () -> Void) -> Detail

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UISplitViewController {
        let split = UISplitViewController(style: .doubleColumn)
        let coordinator = context.coordinator
        coordinator.split = split
        split.delegate = coordinator
        split.preferredDisplayMode = .oneBesideSecondary
        // The detail toolbar provides the toggle in both expanded and collapsed layouts.
        split.displayModeButtonVisibility = .never
        coordinator.sidebar.view.backgroundColor = .clear
        split.primaryBackgroundStyle = .sidebar
        split.minimumPrimaryColumnWidth = 260
        split.maximumPrimaryColumnWidth = 380
        split.preferredPrimaryColumnWidthFraction = 0.28
        for (host, column) in [(coordinator.sidebar, UISplitViewController.Column.primary), (coordinator.detail, .secondary)] {
            let navigation = UINavigationController(rootViewController: host)
            // The primary uses the native bar to reserve space for iPad window controls.
            navigation.setNavigationBarHidden(column == .secondary, animated: false)
            if column == .primary { navigation.delegate = coordinator }
            split.setViewController(navigation, for: column)
        }
        updateUIViewController(split, context: context)
        return split
    }

    func updateUIViewController(_ split: UISplitViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.hasSelection = hasSelection
        coordinator.sidebar.rootView = AnyView(
            sidebar { [weak coordinator] in coordinator?.showDetail() }
                .environment(\.self, context.environment)
        )
        coordinator.detail.rootView = AnyView(
            NavigationStack { detail { [weak coordinator] in coordinator?.toggleSidebar() } }
                .environment(\.self, context.environment)
        )
    }

    final class Coordinator: NSObject, UISplitViewControllerDelegate, UINavigationControllerDelegate {
        weak var split: UISplitViewController?
        let sidebar = UIHostingController(rootView: AnyView(EmptyView()))
        let detail = UIHostingController(rootView: AnyView(EmptyView()))
        var hasSelection = false

        func navigationController(_ navigationController: UINavigationController,
                                  willShow viewController: UIViewController, animated: Bool) {
            // On collapse, UIKit moves the detail into the primary navigation stack.
            // Its SwiftUI NavigationStack already owns the detail toolbar.
            navigationController.setNavigationBarHidden(viewController !== sidebar, animated: animated)
        }

        func showDetail() {
            guard let split, split.isCollapsed else { return }
            split.show(.secondary)
        }

        func toggleSidebar() {
            guard let split else { return }
            if split.isCollapsed || split.displayMode == .secondaryOnly {
                split.show(.primary)
            } else {
                split.hide(.primary)
            }
        }

        func splitViewController(_ svc: UISplitViewController,
                                 topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
            hasSelection ? .secondary : .primary
        }
    }
}
#endif
