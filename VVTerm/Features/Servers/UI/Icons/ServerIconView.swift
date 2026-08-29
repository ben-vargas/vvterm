import SwiftUI

struct ServerIconView: View {
    let selection: ServerIconSelection
    let detectedSystemIdentity: RemoteSystemIdentity?
    var size: CGFloat = 24
    var tint: Color = .secondary

    init(
        server: Server,
        size: CGFloat = 24,
        tint: Color = .secondary
    ) {
        selection = server.iconSelection
        detectedSystemIdentity = server.detectedSystemIdentity
        self.size = size
        self.tint = tint
    }

    init(
        selection: ServerIconSelection,
        detectedSystemIdentity: RemoteSystemIdentity?,
        size: CGFloat = 24,
        tint: Color = .secondary
    ) {
        self.selection = selection
        self.detectedSystemIdentity = detectedSystemIdentity
        self.size = size
        self.tint = tint
    }

    var body: some View {
        ServerIconArtworkView(
            presentation: ServerIconPresentationResolver.presentation(
                selection: selection,
                detectedSystemIdentity: detectedSystemIdentity
            ),
            size: size,
            tint: tint
        )
        .accessibilityHidden(true)
    }
}

private struct ServerIconArtworkView: View {
    let presentation: ServerIconPresentation
    let size: CGFloat
    let tint: Color

    @Environment(\.serverIconArtworkResolver) private var artworkResolver

    var body: some View {
        Group {
            switch presentation {
            case .systemImage(let name):
                Image(systemName: name)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(tint)

            case .asset(let name):
                Image(name)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()

            case .appleDevice(let modelIdentifier, let fallbackSystemImage):
                if let appleDeviceImage = artworkResolver.image(for: modelIdentifier) {
                    appleDeviceImage
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: fallbackSystemImage)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(tint)
                }
            }
        }
        .frame(width: size, height: size)
    }
}
