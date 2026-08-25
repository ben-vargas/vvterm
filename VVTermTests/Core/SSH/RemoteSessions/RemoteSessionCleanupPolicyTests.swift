import Foundation
import Testing
@testable import VVTerm

struct RemoteSessionCleanupPolicyTests {
    @Test
    func deletesOnlyUnretainedManagedSessionsThatAreSafeToDelete() throws {
        let attached = try identifier("vvterm-prod-dabcd-s111111")
        let detached = try identifier("vvterm-prod-dabcd-s222222")
        let stopped = try identifier("vvterm-prod-dabcd-s333333")
        let unknown = try identifier("vvterm-prod-dabcd-s444444")
        let retained = try identifier("vvterm-prod-dabcd-s555555")
        let external = try identifier("shared")
        let sessions = [
            descriptor(attached, disposition: .inUse),
            descriptor(detached, disposition: .safeToDelete),
            descriptor(stopped, disposition: .safeToDelete),
            descriptor(unknown, disposition: .unknown),
            descriptor(retained, disposition: .safeToDelete),
            descriptor(external, disposition: .safeToDelete)
        ]

        let result = RemoteSessionCleanupPolicy.identifiersToDelete(
            from: sessions,
            keeping: [retained],
            isManaged: { $0.rawValue.hasPrefix("vvterm-") }
        )

        #expect(result == [detached, stopped])
    }

    private func identifier(_ rawValue: String) throws -> RemoteSessionIdentifier {
        try RemoteSessionIdentifier(backendIdentifier: .tmux, validating: rawValue)
    }

    private func descriptor(
        _ identifier: RemoteSessionIdentifier,
        disposition: RemoteSessionCleanupDisposition
    ) -> RemoteSessionDescriptor {
        RemoteSessionDescriptor(
            id: identifier,
            attachedClientCount: nil,
            containerCount: nil,
            cleanupDisposition: disposition
        )
    }
}
