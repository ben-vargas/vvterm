#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import VVTerm

@MainActor
final class AdaptiveServerNavigationTests: XCTestCase {
    func testCollapsedDetailHidesOuterBarAndReturningRestoresIt() {
        let coordinator = AdaptiveServerNavigation<EmptyView, EmptyView>.Coordinator()
        let navigation = UINavigationController(rootViewController: coordinator.sidebar)
        navigation.delegate = coordinator
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        navigation.view.layoutIfNeeded()
        XCTAssertFalse(navigation.isNavigationBarHidden)

        // The split controller pushes its secondary controller into this stack on collapse.
        navigation.pushViewController(coordinator.detail, animated: false)
        navigation.view.layoutIfNeeded()
        XCTAssertTrue(navigation.isNavigationBarHidden)

        navigation.popViewController(animated: false)
        navigation.view.layoutIfNeeded()
        XCTAssertFalse(navigation.isNavigationBarHidden)
    }
}
#endif
