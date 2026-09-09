import Foundation
import SwiftUI
import Testing
@testable import VVTerm

@MainActor
struct LocalDeviceDiscoveryPresentationTests {
    @Test
    func privacyModePreservesDiscoveryRowText() throws {
        let host = DiscoveredSSHHost(
            displayName: "Office Mac",
            host: "192.0.2.10",
            port: 2222,
            sources: [.bonjour]
        )
        try expectSameRenderingWithPrivacyMode(DiscoveryHostRow(host: host))
        #if os(macOS)
        try expectSameRenderingWithPrivacyMode(DiscoveryHostSwitcherRow(
            host: host,
            isSelected: false,
            isHovered: false,
            onSelect: {},
            onUse: {}
        ))
        #endif
    }

    private func expectSameRenderingWithPrivacyMode(_ row: some View) throws {
        func pixels(privacyModeEnabled: Bool) throws -> Data {
            let renderer = ImageRenderer(content: row
                .environment(\.privacyModeEnabled, privacyModeEnabled)
                .environment(\.colorScheme, .light)
                .frame(width: 480, height: 60))
            let image = try #require(renderer.cgImage)
            let data = try #require(image.dataProvider?.data)
            return data as Data
        }
        let visible = try pixels(privacyModeEnabled: false)
        #expect(!visible.isEmpty)
        #expect(try pixels(privacyModeEnabled: true) == visible)
    }

    @Test
    func factoryCreatesOneStableManagerForEachPresentation() {
        var creationCount = 0
        let service = LocalDeviceDiscoveryServiceFake()
        let factory: LocalSSHDiscoveryManagerFactory = {
            creationCount += 1
            return LocalSSHDiscoveryManager(
                dependencies: LocalSSHDiscoveryDependencies(
                    service: service,
                    networkAvailability: { .supported },
                    makeScanID: UUID.init
                )
            )
        }

        let first = LocalDeviceDiscoveryPresentation(makeManager: factory)
        let firstManager = first.manager

        #expect(creationCount == 1)
        #expect(first.manager === firstManager)

        let second = LocalDeviceDiscoveryPresentation(makeManager: factory)

        #expect(creationCount == 2)
        #expect(second.manager !== firstManager)
        #expect(second.id != first.id)
        #expect(service.startCount == 0)
    }
}

@MainActor
private final class LocalDeviceDiscoveryServiceFake: LocalSSHDiscovering {
    private(set) var startCount = 0

    var ownerReleaseStopRequest: LocalSSHDiscoveryStopRequest {
        LocalSSHDiscoveryStopRequest(stop: {})
    }

    func startScan() -> AsyncStream<LocalSSHDiscoveryEvent> {
        startCount += 1
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func stopScan() {}
}
