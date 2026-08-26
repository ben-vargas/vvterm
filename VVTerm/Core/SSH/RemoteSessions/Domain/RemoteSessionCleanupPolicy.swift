import Foundation

nonisolated enum RemoteSessionCleanupPolicy {
    static func identifiersToDelete(
        from sessions: [RemoteSessionDescriptor],
        keeping identifiers: Set<RemoteSessionIdentifier>
    ) -> [RemoteSessionIdentifier] {
        sessions.compactMap { session in
            guard session.cleanupDisposition == .safeToDelete,
                  session.attachment.ownership == .managed,
                  !identifiers.contains(session.id) else {
                return nil
            }
            return session.id
        }
    }
}
