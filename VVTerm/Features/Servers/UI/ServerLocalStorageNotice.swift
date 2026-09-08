import SwiftUI

struct ServerLocalStorageNotice: View {
    let serverManager: ServerManager
    @ObservedObject var stateStore: ServerStateStore
    @State private var isShowingCloudRecovery = false

    init(serverManager: ServerManager) {
        self.serverManager = serverManager
        _stateStore = ObservedObject(wrappedValue: serverManager.stateStore)
    }

    var body: some View {
        if stateStore.ambiguousCloudRecovery != nil || !stateStore.localStorageIssues.isEmpty {
            Group {
                if stateStore.ambiguousCloudRecovery != nil {
                    NoticeBannerView(
                        item: NoticeItem(
                            id: "server-cloud-recovery",
                            lane: .topBanner,
                            level: .warning,
                            leading: .icon("icloud.slash"),
                            title: String(localized: "Cloud data needs review"),
                            message: String(localized: "Your local data is safe. Choose how to continue."),
                            action: NoticeAction(
                                id: "review-cloud-recovery",
                                title: String(localized: "Review"),
                                handler: { isShowingCloudRecovery = true }
                            )
                        )
                    )
                } else {
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
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .modifier(ServerCloudRecoveryPresentation(
                isPresented: $isShowingCloudRecovery,
                resolve: serverManager.resolveAmbiguousCloudRecovery
            ))
        }
    }
}
