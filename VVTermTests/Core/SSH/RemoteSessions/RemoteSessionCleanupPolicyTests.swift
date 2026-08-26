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
            descriptor(attached, ownership: .managed, disposition: .inUse),
            descriptor(detached, ownership: .managed, disposition: .safeToDelete),
            descriptor(stopped, ownership: .managed, disposition: .safeToDelete),
            descriptor(unknown, ownership: .managed, disposition: .unknown),
            descriptor(retained, ownership: .managed, disposition: .safeToDelete),
            descriptor(external, ownership: .external, disposition: .safeToDelete)
        ]

        let result = RemoteSessionCleanupPolicy.identifiersToDelete(
            from: sessions,
            keeping: [retained]
        )

        #expect(result == [detached, stopped])
    }

    @Test
    func userOwnedVVTermStyleNameIsNeverDeleted() throws {
        let external = try identifier("vvterm-prod-dabcd-s111111")
        let managed = try identifier("managed-without-name-convention")

        let result = RemoteSessionCleanupPolicy.identifiersToDelete(
            from: [
                descriptor(external, ownership: .external, disposition: .safeToDelete),
                descriptor(managed, ownership: .managed, disposition: .safeToDelete)
            ],
            keeping: []
        )

        #expect(result == [managed])
    }

    private func identifier(_ rawValue: String) throws -> RemoteSessionIdentifier {
        try RemoteSessionIdentifier(backendIdentifier: .tmux, validating: rawValue)
    }

    private func descriptor(
        _ identifier: RemoteSessionIdentifier,
        ownership: RemoteSessionOwnership,
        disposition: RemoteSessionCleanupDisposition
    ) -> RemoteSessionDescriptor {
        RemoteSessionDescriptor(
            attachment: RemoteSessionAttachment(
                identifier: identifier,
                ownership: ownership
            ),
            attachedClientCount: nil,
            containerCount: nil,
            cleanupDisposition: disposition
        )
    }
}
