import Foundation

nonisolated struct RemoteSessionBackendRegistry: Sendable {
    private let backends: [RemoteSessionBackendIdentifier: any RemoteSessionBackend]

    init(backends: [any RemoteSessionBackend]) {
        var indexed: [RemoteSessionBackendIdentifier: any RemoteSessionBackend] = [:]
        for backend in backends {
            precondition(indexed[backend.metadata.identifier] == nil)
            indexed[backend.metadata.identifier] = backend
        }
        self.backends = indexed
    }

    var metadata: [RemoteSessionBackendMetadata] {
        backends.values.map(\.metadata).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func backend(
        for identifier: RemoteSessionBackendIdentifier
    ) -> (any RemoteSessionBackend)? {
        backends[identifier]
    }
}
