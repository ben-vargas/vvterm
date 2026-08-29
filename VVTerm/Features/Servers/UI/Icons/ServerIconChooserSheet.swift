import SwiftUI

struct ServerIconChooserSheet: View {
    @Binding var selection: ServerIconSelection
    let detectedSystemIdentity: RemoteSystemIdentity?
    let automaticStatusText: String
    let isDetecting: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @ScaledMetric(relativeTo: .body) private var iconSize = 22

    var body: some View {
        platformBody
            .accessibilityIdentifier("vvterm.serverIcon.chooser")
    }

    var searchTextBinding: Binding<String> {
        $searchText
    }

    func close() {
        dismiss()
    }

    var formContent: some View {
        List {
            Section {
                selectionButton(
                    selection: .automatic,
                    title: String(localized: "Automatic"),
                    detail: automaticStatusText,
                    isDetecting: isDetecting,
                    accessibilityIdentifier: "vvterm.serverIcon.automatic"
                )
            }

            iconSection(
                title: "General",
                icons: filteredIcons(ServerIconCatalog.genericIcons),
                accessibilityIdentifier: "vvterm.serverIcon.section.general"
            )

            iconSection(
                title: "Apple Devices",
                icons: filteredIcons(ServerIconCatalog.appleDeviceIcons),
                accessibilityIdentifier: "vvterm.serverIcon.section.appleDevices"
            )

            iconSection(
                title: "Operating Systems",
                icons: filteredIcons(ServerIconCatalog.operatingSystemIcons),
                accessibilityIdentifier: "vvterm.serverIcon.section.operatingSystems"
            )

            if hasNoMatches {
                Section {
                    Label("No Results", systemImage: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func iconSection(
        title: LocalizedStringKey,
        icons: [ServerIconID],
        accessibilityIdentifier: String
    ) -> some View {
        if !icons.isEmpty {
            Section {
                ForEach(icons) { iconID in
                    selectionButton(
                        selection: .custom(iconID),
                        title: iconID.displayName,
                        accessibilityIdentifier: "vvterm.serverIcon.custom.\(iconID.rawValue)"
                    )
                }
            } header: {
                Text(title)
                    .accessibilityIdentifier(accessibilityIdentifier)
            }
        }
    }

    private func selectionButton(
        selection candidate: ServerIconSelection,
        title: String,
        detail: String? = nil,
        isDetecting: Bool = false,
        accessibilityIdentifier: String
    ) -> some View {
        Button {
            selection = candidate
            close()
        } label: {
            HStack(spacing: 10) {
                ServerIconView(
                    selection: candidate,
                    detectedSystemIdentity: detectedSystemIdentity,
                    size: iconSize,
                    tint: .accentColor
                )
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)

                    if let detail {
                        Text(detail)
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

                if selection == candidate {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16))
        .accessibilityAddTraits(selection == candidate ? .isSelected : [])
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasNoMatches: Bool {
        !normalizedSearchText.isEmpty
            && filteredIcons(ServerIconID.allCases).isEmpty
    }

    private func filteredIcons(_ icons: [ServerIconID]) -> [ServerIconID] {
        guard !normalizedSearchText.isEmpty else { return icons }
        return icons.filter {
            $0.displayName.localizedCaseInsensitiveContains(normalizedSearchText)
                || $0.rawValue.localizedCaseInsensitiveContains(normalizedSearchText)
        }
    }
}
