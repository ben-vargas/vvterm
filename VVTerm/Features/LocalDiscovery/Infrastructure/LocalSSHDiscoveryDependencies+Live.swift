import Foundation

extension LocalSSHDiscoveryService: LocalSSHDiscovering {}

extension LocalSSHDiscoveryDependencies {
    static var live: Self {
        LocalSSHDiscoveryDependencies(
            service: LocalSSHDiscoveryService(),
            networkAvailability: {
                NetworkMonitor.shared.connectionType == .cellular
                    ? .unsupported
                    : .supported
            },
            makeScanID: UUID.init
        )
    }
}

extension LocalSSHDiscoveryManager {
    convenience init() {
        self.init(dependencies: .live)
    }
}
