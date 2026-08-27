import Combine
import Foundation

@MainActor
final class TerminalFontCatalogStore: ObservableObject {
    typealias LoadCatalog = @MainActor () -> TerminalFontCatalog

    @Published private(set) var catalog: TerminalFontCatalog

    private let loadCatalog: LoadCatalog

    init(loadCatalog: @escaping LoadCatalog) {
        self.loadCatalog = loadCatalog
        catalog = loadCatalog()
    }

    func refresh() {
        let updatedCatalog = loadCatalog()
        guard updatedCatalog != catalog else { return }
        catalog = updatedCatalog
    }
}
