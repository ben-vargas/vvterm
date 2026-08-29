#if os(macOS)
import SwiftUI

extension ServerIconChooserSheet {
    var platformBody: some View {
        VStack(spacing: 0) {
            DialogSheetHeader(title: "Icon") {
                close()
            }

            Divider()

            SearchField(placeholder: "Search Icons", text: searchTextBinding)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            formContent
                .listStyle(.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: 640)
        .adaptiveSoftScrollEdges()
    }
}
#endif
