#if os(macOS)
import AppKit
import Testing
import UniformTypeIdentifiers
@testable import VVTerm

@MainActor
struct MacSystemAppleDeviceArtworkProviderTests {
    @Test
    func liveProviderResolvesThisMacBookModelArtwork() throws {
        let model = try #require(
            AppleHardwareModelIdentifier(rawValue: "MacBookPro18,3")
        )

        let image = MacSystemAppleDeviceArtworkProvider.live.image(for: model)

        #expect(image != nil)
        #expect(image?.isValid == true)
    }

    @Test
    func providerUsesOnlyDeclaredNonDynamicType() throws {
        let model = try #require(AppleHardwareModelIdentifier(rawValue: "MacBookPro18,3"))
        let dynamicType = try #require(UTType(filenameExtension: "vvterm-unknown-device-type"))
        var requestedTag: String?
        var requestedTagClass: UTTagClass?
        var iconType: UTType?
        let expectedImage = NSImage(size: NSSize(width: 32, height: 32))
        let provider = MacSystemAppleDeviceArtworkProvider(
            types: { tag, tagClass in
                requestedTag = tag
                requestedTagClass = tagClass
                return [dynamicType, .plainText]
            },
            icon: { type in
                iconType = type
                return expectedImage
            }
        )

        let image = provider.image(for: model)

        #expect(image === expectedImage)
        #expect(requestedTag == model.rawValue)
        #expect(requestedTagClass == MacSystemAppleDeviceArtworkProvider.deviceModelTagClass)
        #expect(iconType == .plainText)
        #expect(dynamicType.isDynamic)
        #expect(UTType.plainText.isDeclared)
    }

    @Test
    func providerRejectsDynamicAndUndeclaredTypes() throws {
        let model = try #require(AppleHardwareModelIdentifier(rawValue: "FutureComputer1,1"))
        let dynamicType = try #require(UTType(filenameExtension: "vvterm-unknown-device-type"))
        var iconCallCount = 0
        let provider = MacSystemAppleDeviceArtworkProvider(
            types: { _, _ in [dynamicType] },
            icon: { _ in
                iconCallCount += 1
                return NSImage(size: .zero)
            }
        )

        #expect(provider.image(for: model) == nil)
        #expect(iconCallCount == 0)
    }
}
#endif
