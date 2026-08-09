import Combine
import Foundation

nonisolated enum TerminalSurfaceRegistryChange: Equatable, Sendable {
    case registered(paneId: UUID, surfaceIdentity: ObjectIdentifier)
    case replaced(paneId: UUID, surfaceIdentity: ObjectIdentifier)
    case removed(paneId: UUID, surfaceIdentity: ObjectIdentifier)
    case drained(surfaceIdentitiesByPane: [UUID: ObjectIdentifier])
}

/// Owns the one current terminal surface identity for each pane.
@MainActor
final class TerminalSurfaceRegistry<Surface: AnyObject>: ObservableObject {
    @Published private(set) var latestChange: TerminalSurfaceRegistryChange?

    private var surfacesByPane: [UUID: Surface] = [:]

    func surface(for paneId: UUID) -> Surface? {
        surfacesByPane[paneId]
    }

    func isRegistered(_ surface: Surface, for paneId: UUID) -> Bool {
        surfacesByPane[paneId] === surface
    }

    @discardableResult
    func register(_ surface: Surface, for paneId: UUID) -> Bool {
        if surfacesByPane[paneId] === surface {
            return false
        }

        let replacedExistingSurface = surfacesByPane[paneId] != nil
        surfacesByPane[paneId] = surface
        if replacedExistingSurface {
            latestChange = .replaced(
                paneId: paneId,
                surfaceIdentity: ObjectIdentifier(surface)
            )
            return true
        }
        latestChange = .registered(
            paneId: paneId,
            surfaceIdentity: ObjectIdentifier(surface)
        )
        return false
    }

    @discardableResult
    func remove(
        for paneId: UUID,
        prepareForRemoval: (Surface) -> Void = { _ in }
    ) -> Surface? {
        guard let surface = surfacesByPane[paneId] else { return nil }
        prepareForRemoval(surface)
        surfacesByPane.removeValue(forKey: paneId)
        latestChange = .removed(
            paneId: paneId,
            surfaceIdentity: ObjectIdentifier(surface)
        )
        return surface
    }

    /// Cleans up a dismantled surface, but removes the pane entry only when
    /// that exact identity is still current.
    @discardableResult
    func unregister(
        _ surface: Surface,
        for paneId: UUID,
        prepareForRemoval: (Surface) -> Void = { _ in },
        cleanup: (Surface) -> Void
    ) -> Bool {
        let removedCurrentSurface: Bool
        if isRegistered(surface, for: paneId) {
            prepareForRemoval(surface)
            surfacesByPane.removeValue(forKey: paneId)
            latestChange = .removed(
                paneId: paneId,
                surfaceIdentity: ObjectIdentifier(surface)
            )
            removedCurrentSurface = true
        } else {
            removedCurrentSurface = false
        }
        cleanup(surface)
        return removedCurrentSurface
    }

    func drain(
        prepareForRemoval: (UUID, Surface) -> Void = { _, _ in },
        cleanup: (Surface) -> Void
    ) {
        guard !surfacesByPane.isEmpty else { return }
        let drained = surfacesByPane
        surfacesByPane.removeAll()
        var cleanedSurfaceIdentities: Set<ObjectIdentifier> = []
        for (paneId, surface) in drained {
            prepareForRemoval(paneId, surface)
            if cleanedSurfaceIdentities.insert(ObjectIdentifier(surface)).inserted {
                cleanup(surface)
            }
        }
        latestChange = .drained(
            surfaceIdentitiesByPane: drained.mapValues(ObjectIdentifier.init)
        )
    }
}
