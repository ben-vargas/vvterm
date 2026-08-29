#if os(macOS)
import AppKit
import UniformTypeIdentifiers

@MainActor
protocol AppleDeviceArtworkProviding {
    func image(for modelIdentifier: AppleHardwareModelIdentifier) -> NSImage?
}

@MainActor
struct MacSystemAppleDeviceArtworkProvider: AppleDeviceArtworkProviding {
    typealias TypeLookup = (_ tag: String, _ tagClass: UTTagClass) -> [UTType]
    typealias IconLookup = (_ type: UTType) -> NSImage

    static let deviceModelTagClass = UTTagClass(rawValue: "com.apple.device-model-code")
    static let live = Self(
        types: { tag, tagClass in
            UTType.types(tag: tag, tagClass: tagClass, conformingTo: nil)
        },
        icon: { type in
            NSWorkspace.shared.icon(for: type)
        }
    )

    private let types: TypeLookup
    private let icon: IconLookup

    init(
        types: @escaping TypeLookup,
        icon: @escaping IconLookup
    ) {
        self.types = types
        self.icon = icon
    }

    func image(for modelIdentifier: AppleHardwareModelIdentifier) -> NSImage? {
        guard let declaredType = types(
            modelIdentifier.rawValue,
            Self.deviceModelTagClass
        ).first(where: { $0.isDeclared && !$0.isDynamic }) else {
            return nil
        }
        return icon(declaredType)
    }
}
#endif
