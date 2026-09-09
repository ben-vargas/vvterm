import Foundation
import Combine

@MainActor
final class TerminalLinkCoordinator: ObservableObject {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let url: URL
    }

    enum Presentation: Equatable {
        case confirmation(Request)
        case opening(Request)
        case failure(Request)
    }

    @Published private(set) var presentation: Presentation?

    func request(_ url: URL) {
        guard presentation == nil,
              let destination = TerminalLinkPolicy.destination(url.absoluteString) else { return }
        presentation = .confirmation(Request(url: destination))
    }

    func open(using opener: (URL, @escaping (Bool) -> Void) -> Void) {
        guard case .confirmation(let request) = presentation else { return }
        presentation = .opening(request)
        opener(request.url) { [weak self] accepted in
            guard let self, self.presentation == .opening(request) else { return }
            self.presentation = accepted ? nil : .failure(request)
        }
    }

    func dismissAlert() {
        switch presentation {
        case .confirmation, .failure: presentation = nil
        case .opening, nil: break
        }
    }

    func cancel() {
        presentation = nil
    }
}
