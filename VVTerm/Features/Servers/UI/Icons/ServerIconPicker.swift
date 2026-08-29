import SwiftUI

struct ServerIconPicker: View {
    @Binding var selection: ServerIconSelection
    let detectedSystemIdentity: RemoteSystemIdentity?
    let isDetecting: Bool

    @State private var isChooserPresented = false
    @ScaledMetric(relativeTo: .body) private var selectedIconSize = 28

    var body: some View {
        Button {
            isChooserPresented = true
        } label: {
            selectedContent
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Icon")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("vvterm.serverIcon.picker")
        .sheet(isPresented: $isChooserPresented) {
            ServerIconChooserSheet(
                selection: $selection,
                detectedSystemIdentity: detectedSystemIdentity,
                automaticStatusText: automaticStatusText,
                isDetecting: isDetecting
            )
        }
    }

    private var selectedContent: some View {
        HStack(spacing: 12) {
            ServerIconView(
                selection: selection,
                detectedSystemIdentity: detectedSystemIdentity,
                size: selectedIconSize,
                tint: .accentColor
            )
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(selectionTitle)
                    .foregroundStyle(.primary)

                if selection == .automatic {
                    Text(automaticStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if isDetecting {
                ProgressView()
                    .controlSize(.small)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectionTitle: String {
        switch selection {
        case .automatic:
            return String(localized: "Automatic")
        case .custom(let iconID):
            return iconID.displayName
        }
    }

    private var automaticStatusText: String {
        if isDetecting {
            return String(localized: "Checking...")
        }
        guard let detectedSystemIdentity else {
            return String(localized: "System not detected")
        }
        return String(
            format: String(localized: "Detected: %@"),
            detectedSystemIdentity.iconDisplayName
        )
    }

    private var accessibilityValue: String {
        selection == .automatic
            ? "\(selectionTitle), \(automaticStatusText)"
            : selectionTitle
    }
}
