import SwiftUI

struct OpenSourceLicensesView: View {
    @Environment(\.dismiss) var dismiss

    let documents: [OpenSourceAttribution.Document]

    init(documents: [OpenSourceAttribution.Document] = OpenSourceAttributionCatalog.bundled) {
        self.documents = documents
    }

    var body: some View {
        platformBody
    }
}

struct OpenSourceLicensesContent: View {
    let documents: [OpenSourceAttribution.Document]

    var body: some View {
        Form {
            Section {
                OpenSourceAcknowledgementHero()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }

            Section("Open Source Projects") {
                if documents.isEmpty {
                    Text("No open-source license information is available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(documents) { document in
                        NavigationLink {
                            OpenSourceAttributionDetailView(document: document)
                        } label: {
                            OpenSourceAttributionRow(document: document)
                        }
                        .accessibilityIdentifier(
                            "vvterm.openSourceLicenses.project.\(document.id)"
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("vvterm.openSourceLicenses")
    }
}

private struct OpenSourceAttributionRow: View {
    let document: OpenSourceAttribution.Document

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(document.attribution.name)
                .foregroundStyle(.primary)

            Text(document.attribution.role.localizedTitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(document.attribution.licenseName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

extension OpenSourceAttribution.Role {
    var localizedTitle: String {
        switch self {
        case .terminalEngine:
            String(localized: "Terminal engine")
        case .networkTransport:
            String(localized: "Network transport")
        case .securityLibrary:
            String(localized: "Security library")
        case .archiveLibrary:
            String(localized: "Archive library")
        case .machineLearningLibrary:
            String(localized: "Machine learning library")
        case .utilityLibrary:
            String(localized: "Utility library")
        case .sessionProtocol:
            String(localized: "Remote session protocol")
        case .speechModel:
            String(localized: "Speech recognition model")
        case .fontCollection:
            String(localized: "Terminal font collection")
        case .themeCollection:
            String(localized: "Terminal theme collection")
        case .artwork:
            String(localized: "Product artwork")
        }
    }
}
