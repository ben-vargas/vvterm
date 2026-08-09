import SwiftUI

struct ServerLocalStorageNotice: View {
    @ObservedObject var stateStore: ServerStateStore

    init(stateStore: ServerStateStore) {
        _stateStore = ObservedObject(wrappedValue: stateStore)
    }

    var body: some View {
        if !stateStore.localStorageIssues.isEmpty {
            NoticeBannerView(
                item: NoticeItem(
                    id: "server-local-storage-unreadable",
                    lane: .topBanner,
                    level: .warning,
                    leading: .icon("externaldrive.badge.exclamationmark"),
                    title: String(localized: "Local data could not be read"),
                    message: String(localized: "VVTerm preserved a backup before using replacement data."),
                    dismissAction: stateStore.dismissLocalStorageIssues
                )
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}
