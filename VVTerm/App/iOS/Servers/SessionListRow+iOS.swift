#if os(iOS)
import SwiftUI

struct SessionListRow: View {
    let entry: SessionListEntry
    let isSelected: Bool

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).foregroundStyle(.primary).lineLimit(2)
                    Text(entry.statusLabel).font(.subheadline).foregroundStyle(.secondary)
                    if entry.panes.count > 1 {
                        Text(LocalizedFormat.string("%lld panes", entry.panes.count)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: entry.icon).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !entry.badges.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { badges }
                    VStack(alignment: .trailing, spacing: 4) { badges }
                }
            }
            if isSelected { Image(systemName: "checkmark").font(.caption).foregroundStyle(.tint) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var badges: some View {
        ForEach(entry.badges, id: \.self) { badge in
            Text(verbatim: badge)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .fixedSize()
        }
    }
}
#endif
