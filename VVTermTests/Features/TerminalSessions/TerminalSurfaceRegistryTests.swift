import Foundation
import Testing
@testable import VVTerm

@MainActor
struct TerminalSurfaceRegistryTests {
    private final class Surface {}

    @Test
    func replacementPublishesTypedChangeAndKeepsStableIdentity() {
        let registry = TerminalSurfaceRegistry<Surface>()
        let paneId = UUID()
        let first = Surface()
        let replacement = Surface()
        let secondReplacement = Surface()

        #expect(!registry.register(first, for: paneId))
        #expect(registry.surface(for: paneId) === first)
        #expect(registry.latestChange == .registered(
            paneId: paneId,
            surfaceIdentity: ObjectIdentifier(first)
        ))

        #expect(!registry.register(first, for: paneId))
        #expect(registry.latestChange == .registered(
            paneId: paneId,
            surfaceIdentity: ObjectIdentifier(first)
        ))

        #expect(registry.register(replacement, for: paneId))
        #expect(registry.surface(for: paneId) === replacement)
        let firstReplacementChange = registry.latestChange
        #expect(firstReplacementChange == .replaced(
            paneId: paneId,
            surfaceIdentity: ObjectIdentifier(replacement)
        ))

        #expect(registry.register(secondReplacement, for: paneId))
        #expect(registry.surface(for: paneId) === secondReplacement)
        #expect(registry.latestChange == .replaced(
            paneId: paneId,
            surfaceIdentity: ObjectIdentifier(secondReplacement)
        ))
        #expect(registry.latestChange != firstReplacementChange)
    }

    @Test
    func staleTeardownCleansOnlyReporterAndPreservesReplacement() {
        let registry = TerminalSurfaceRegistry<Surface>()
        let paneId = UUID()
        let stale = Surface()
        let replacement = Surface()
        var cleaned: [ObjectIdentifier] = []
        registry.register(stale, for: paneId)
        registry.register(replacement, for: paneId)

        let removed = registry.unregister(stale, for: paneId) {
            cleaned.append(ObjectIdentifier($0))
        }

        #expect(!removed)
        #expect(cleaned == [ObjectIdentifier(stale)])
        #expect(registry.surface(for: paneId) === replacement)
        #expect(registry.latestChange == .replaced(
            paneId: paneId,
            surfaceIdentity: ObjectIdentifier(replacement)
        ))
    }

    @Test
    func twoRegistriesDoNotShareSurfacesOrChanges() {
        let firstRegistry = TerminalSurfaceRegistry<Surface>()
        let secondRegistry = TerminalSurfaceRegistry<Surface>()
        let paneId = UUID()
        let surface = Surface()

        firstRegistry.register(surface, for: paneId)

        #expect(firstRegistry.surface(for: paneId) === surface)
        #expect(secondRegistry.surface(for: paneId) == nil)
        #expect(firstRegistry.latestChange == .registered(
            paneId: paneId,
            surfaceIdentity: ObjectIdentifier(surface)
        ))
        #expect(secondRegistry.latestChange == nil)
    }

    @Test
    func drainCleansEachRegisteredSurfaceExactlyOnce() {
        let registry = TerminalSurfaceRegistry<Surface>()
        let firstPaneId = UUID()
        let secondPaneId = UUID()
        let duplicatePaneId = UUID()
        let first = Surface()
        let second = Surface()
        var cleanupCounts: [ObjectIdentifier: Int] = [:]
        registry.register(first, for: firstPaneId)
        registry.register(second, for: secondPaneId)
        registry.register(first, for: duplicatePaneId)

        registry.drain { surface in
            cleanupCounts[ObjectIdentifier(surface), default: 0] += 1
        }
        registry.drain { surface in
            cleanupCounts[ObjectIdentifier(surface), default: 0] += 1
        }

        #expect(cleanupCounts[ObjectIdentifier(first)] == 1)
        #expect(cleanupCounts[ObjectIdentifier(second)] == 1)
        #expect(registry.surface(for: firstPaneId) == nil)
        #expect(registry.surface(for: secondPaneId) == nil)
        #expect(registry.surface(for: duplicatePaneId) == nil)
        #expect(registry.latestChange == .drained(
            surfaceIdentitiesByPane: [
                firstPaneId: ObjectIdentifier(first),
                secondPaneId: ObjectIdentifier(second),
                duplicatePaneId: ObjectIdentifier(first),
            ]
        ))
    }
}
