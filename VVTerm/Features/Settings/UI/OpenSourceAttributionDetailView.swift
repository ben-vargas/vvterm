import SwiftUI

struct OpenSourceAttributionDetailView: View {
    let document: OpenSourceAttribution.Document

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(document.attribution.role.localizedTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(document.attribution.licenseName)
                        .font(.callout.weight(.semibold))
                }

                Link(destination: document.attribution.projectURL) {
                    Label("Project Website", systemImage: "arrow.up.right.square")
                }

                Divider()

                Text("License & Notices")
                    .font(.headline)

                Text(verbatim: document.legalText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("vvterm.openSourceLicenses.legalText")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(document.attribution.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
