import SwiftUI

@MainActor
struct ServerIconArtworkResolver {
    static let unavailable = Self { _ in nil }

    private let resolve: (AppleHardwareModelIdentifier) -> Image?

    init(resolve: @escaping (AppleHardwareModelIdentifier) -> Image?) {
        self.resolve = resolve
    }

    func image(for modelIdentifier: AppleHardwareModelIdentifier) -> Image? {
        resolve(modelIdentifier)
    }
}

extension EnvironmentValues {
    @Entry var serverIconArtworkResolver = ServerIconArtworkResolver.unavailable
}
