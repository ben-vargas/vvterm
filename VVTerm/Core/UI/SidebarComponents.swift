import SwiftUI

// MARK: - Pill Badge

struct PillBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: - Search Field

struct SearchField<Trailing: View>: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    var spacing: CGFloat = 8
    var iconSize: CGFloat = 14
    var iconWeight: Font.Weight? = nil
    var iconColor: Color = .secondary
    var textFont: Font = .system(size: 14)
    var clearButtonSize: CGFloat = 12
    var clearButtonWeight: Font.Weight? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: spacing) {
            if let weight = iconWeight {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: iconSize, weight: weight))
                    .foregroundStyle(iconColor)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: iconSize))
                    .foregroundStyle(iconColor)
            }

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(textFont)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: clearButtonSize, weight: clearButtonWeight ?? .regular))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            trailing()
        }
    }
}

extension SearchField where Trailing == EmptyView {
    init(placeholder: LocalizedStringKey, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
        self.spacing = 8
        self.iconSize = 14
        self.iconWeight = nil
        self.iconColor = .secondary
        self.textFont = .system(size: 14)
        self.clearButtonSize = 12
        self.clearButtonWeight = nil
        self.trailing = { EmptyView() }
    }
}
