import Testing
@testable import VVTerm

@MainActor
private final class KnownHostSettingsRepositorySpy: KnownHostSettingsRepository {
    var storedCount = 0
    var countLoadCount = 0
    var removalCount = 0

    func loadKnownHostCount() -> Int {
        countLoadCount += 1
        return storedCount
    }

    func removeAllKnownHosts() {
        removalCount += 1
        storedCount = 0
    }
}

@MainActor
struct KnownHostSettingsCoordinatorTests {
    @Test
    func loadPublishesKnownHostCount() {
        let repository = KnownHostSettingsRepositorySpy()
        repository.storedCount = 3
        let coordinator = KnownHostSettingsCoordinator(repository: repository)

        coordinator.loadCount()

        #expect(coordinator.knownHostCount == 3)
        #expect(repository.countLoadCount == 1)
    }

    @Test
    func successfulRemovalReloadsCount() {
        let repository = KnownHostSettingsRepositorySpy()
        repository.storedCount = 2
        let coordinator = KnownHostSettingsCoordinator(repository: repository)
        coordinator.loadCount()

        coordinator.removeAllKnownHosts()

        #expect(coordinator.knownHostCount == 0)
        #expect(repository.removalCount == 1)
        #expect(repository.countLoadCount == 2)
    }
}
