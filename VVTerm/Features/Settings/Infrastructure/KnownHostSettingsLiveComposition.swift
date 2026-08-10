@MainActor
private final class AppKnownHostSettingsRepository: KnownHostSettingsRepository {
    private let knownHosts: KnownHostsManager

    init(knownHosts: KnownHostsManager) {
        self.knownHosts = knownHosts
    }

    func loadKnownHostCount() -> Int {
        knownHosts.entries().count
    }

    func removeAllKnownHosts() {
        knownHosts.removeAll()
    }
}

@MainActor
enum KnownHostSettingsLiveComposition {
    static func makeCoordinator(
        knownHosts: KnownHostsManager
    ) -> KnownHostSettingsCoordinator {
        KnownHostSettingsCoordinator(
            repository: AppKnownHostSettingsRepository(knownHosts: knownHosts)
        )
    }
}
