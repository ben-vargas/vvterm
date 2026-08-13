import SwiftUI

struct SyncSettingsSummaryRow: View {
    let title: LocalizedStringResource
    let systemImage: String
    let summary: String

    var body: some View {
        platformBody
            .accessibilityElement(children: .combine)
    }
}
