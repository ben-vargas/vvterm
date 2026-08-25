import Foundation

nonisolated enum RemoteSessionCleanupPolicy {
    static func identifiersToDelete(
        from sessions: [RemoteSessionDescriptor],
        keeping identifiers: Set<RemoteSessionIdentifier>,
        isManaged: (RemoteSessionIdentifier) -> Bool
    ) -> [RemoteSessionIdentifier] {
        sessions.compactMap { session in
            guard session.cleanupDisposition == .safeToDelete,
                  isManaged(session.id),
                  !identifiers.contains(session.id) else {
                return nil
            }
            return session.id
        }
    }
}
