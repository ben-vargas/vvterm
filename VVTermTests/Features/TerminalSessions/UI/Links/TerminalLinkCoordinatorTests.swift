import Foundation
import Testing
@testable import VVTerm

@MainActor
struct TerminalLinkCoordinatorTests {
    private let url = URL(string: "https://example.com/actual")!

    @Test
    func cancellationDoesNotOpenLink() {
        let coordinator = TerminalLinkCoordinator()
        coordinator.request(url)
        coordinator.cancel()
        var opened = false
        coordinator.open { _, _ in opened = true }
        #expect(!opened)
        #expect(coordinator.presentation == nil)
    }

    @Test
    func confirmationOpensDestinationOnlyOnce() {
        let coordinator = TerminalLinkCoordinator()
        coordinator.request(url)
        var opened: [URL] = []
        let opener: (URL, @escaping (Bool) -> Void) -> Void = { url, completion in
            opened.append(url)
            completion(true)
        }
        coordinator.open(using: opener)
        coordinator.open(using: opener)
        #expect(opened == [url])
        #expect(coordinator.presentation == nil)
    }

    @Test
    func failedOpeningIsVisibleAndCanBeDismissed() {
        let coordinator = TerminalLinkCoordinator()
        coordinator.request(url)
        coordinator.open { _, completion in completion(false) }
        guard case .failure(let request) = coordinator.presentation else {
            Issue.record("Expected a visible link failure")
            return
        }
        #expect(request.url == url)
        coordinator.dismissAlert()
        #expect(coordinator.presentation == nil)
    }

    @Test
    func closingAlertDoesNotCancelOpeningButHidingTerminalDoes() {
        let coordinator = TerminalLinkCoordinator()
        coordinator.request(url)
        var complete: ((Bool) -> Void)?
        coordinator.open { _, completion in complete = completion }
        coordinator.dismissAlert()
        guard case .opening = coordinator.presentation else {
            Issue.record("Alert dismissal must preserve the pending open result")
            return
        }
        coordinator.cancel()
        coordinator.request(url)
        let next = coordinator.presentation
        complete?(false)
        #expect(coordinator.presentation == next)
    }

    @Test
    func anotherRequestDoesNotReplaceTheVisibleDestination() {
        let coordinator = TerminalLinkCoordinator()
        coordinator.request(url)
        coordinator.request(URL(string: "https://example.com/other")!)
        guard case .confirmation(let request) = coordinator.presentation else {
            Issue.record("Expected confirmation")
            return
        }
        #expect(request.url == url)
    }
}
