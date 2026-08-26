#if os(macOS)
import SwiftUI

extension OpenSourceLicensesView {
    var platformBody: some View {
        NavigationStack {
            OpenSourceLicensesContent(documents: documents)
                .navigationTitle(Text("Open Source & Licenses"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            dismiss()
                        }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("vvterm.openSourceLicenses.close")
                    }
                }
        }
        .frame(minWidth: 720, minHeight: 640)
        .adaptiveSoftScrollEdges()
    }
}

struct OpenSourceAcknowledgementHero: View {
    @ScaledMetric(relativeTo: .title2) private var iconSize = 34.0

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "heart.fill")
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(.pink)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Thank you")
                    .font(.headline)

                Text("VVTerm is built with open source. Thank you for making it possible.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("vvterm.openSourceLicenses.thankYou")
    }
}
#endif
