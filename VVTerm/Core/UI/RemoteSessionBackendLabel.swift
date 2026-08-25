import SwiftUI

struct RemoteSessionBackendLabel: View {
    let backend: RemoteSessionBackendMetadata

    var body: some View {
        HStack(spacing: 0) {
            icon
                .frame(width: 20, height: 20)
                .clipped()
                .frame(width: 32, height: 20, alignment: .leading)

            Text(backend.displayName)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let assetName {
            Image(decorative: assetName)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "terminal")
                .accessibilityHidden(true)
        }
    }

    private var assetName: String? {
        switch backend.identifier.rawValue {
        case "tmux", "zmx":
            "RemoteSessionBackend-\(backend.identifier.rawValue)"
        default:
            nil
        }
    }
}
