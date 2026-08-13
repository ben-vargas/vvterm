#if os(iOS)
import SwiftUI

extension SyncSettingsSummaryRow {
    var platformBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 28)
        }
    }
}
#endif
