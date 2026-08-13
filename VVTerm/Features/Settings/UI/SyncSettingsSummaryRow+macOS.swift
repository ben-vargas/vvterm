#if os(macOS)
import SwiftUI

extension SyncSettingsSummaryRow {
    var platformBody: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(summary)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
