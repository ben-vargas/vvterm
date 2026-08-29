#if os(macOS)
import SwiftUI

extension ServerIconArtworkResolver {
    static let live = Self { modelIdentifier in
        MacSystemAppleDeviceArtworkProvider.live.image(for: modelIdentifier)
            .map(Image.init(nsImage:))
    }
}

extension View {
    func installLiveServerIconArtwork() -> some View {
        environment(
            \.serverIconArtworkResolver,
            ServerIconArtworkResolver.live
        )
    }
}
#endif
