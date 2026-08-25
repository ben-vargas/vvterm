import SwiftUI

struct RemoteSessionBackendLabel: View {
    let backend: RemoteSessionBackendMetadata

    var body: some View {
        Label {
            Text(backend.displayName)
        } icon: {
            icon
                .frame(width: 20, height: 20)
                .clipped()
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
