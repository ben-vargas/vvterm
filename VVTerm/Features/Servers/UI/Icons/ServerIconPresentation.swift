import Foundation

nonisolated enum ServerIconPresentation: Equatable, Sendable {
    case systemImage(String)
    case asset(String)
    case appleDevice(
        modelIdentifier: AppleHardwareModelIdentifier,
        fallbackSystemImage: String
    )
}

nonisolated enum ServerIconPresentationResolver {
    static func presentation(
        selection: ServerIconSelection,
        detectedSystemIdentity: RemoteSystemIdentity?
    ) -> ServerIconPresentation {
        switch selection {
        case .custom(let iconID):
            return presentation(for: iconID)

        case .automatic:
            guard let identity = detectedSystemIdentity else {
                return presentation(for: .server)
            }
            if identity.kind == .macOS,
               let modelIdentifier = identity.appleHardwareModelIdentifier {
                return .appleDevice(
                    modelIdentifier: modelIdentifier,
                    fallbackSystemImage: fallbackSystemImage(for: modelIdentifier.family)
                )
            }
            return presentation(for: ServerIconID.automaticIcon(for: identity.kind))
        }
    }

    private static func presentation(for iconID: ServerIconID) -> ServerIconPresentation {
        if let assetName = iconID.assetName {
            return .asset(assetName)
        }
        return .systemImage(iconID.systemImageName)
    }

    private static func fallbackSystemImage(
        for family: AppleHardwareModelIdentifier.Family
    ) -> String {
        switch family {
        case .macBook: ServerIconID.macBook.systemImageName
        case .macMini: ServerIconID.macMini.systemImageName
        case .macStudio: ServerIconID.macStudio.systemImageName
        case .iMac: ServerIconID.iMac.systemImageName
        case .macPro: ServerIconID.macPro.systemImageName
        case .unknown: ServerIconID.macOS.systemImageName
        }
    }
}
