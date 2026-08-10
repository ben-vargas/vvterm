import Combine

@MainActor
protocol KnownHostSettingsRepository: AnyObject {
    func loadKnownHostCount() -> Int
    func removeAllKnownHosts()
}

@MainActor
final class KnownHostSettingsCoordinator: ObservableObject {
    @Published private(set) var knownHostCount = 0

    private let repository: any KnownHostSettingsRepository

    init(repository: any KnownHostSettingsRepository) {
        self.repository = repository
    }

    func loadCount() {
        knownHostCount = repository.loadKnownHostCount()
    }

    func removeAllKnownHosts() {
        repository.removeAllKnownHosts()
        loadCount()
    }
}
