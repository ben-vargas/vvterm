import StoreKit
import SwiftUI

struct ProSettingsView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var storeManager: StoreManager
    @EnvironmentObject private var serverManager: ServerManager
    @State private var showingPlans = false
    @State private var showingManageSubscription = false

    var body: some View {
        Form {
            Section {
                ProSettingsStatusHero(
                    state: userState,
                    onPrimaryAction: handlePrimaryAction
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }

            if storeManager.accessState == .free {
                usageSection
            }

            if userState.hasProAccess {
                featuresSection
            }

            Section("Purchases") {
                Button("Restore Purchases") {
                    Task { await storeManager.restorePurchases() }
                }
            }

            Section("Legal") {
                Link(destination: URL(string: "https://vvterm.com/privacy/")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                .tint(.primary)
                .foregroundStyle(.primary)

                Link(destination: URL(string: "https://vvterm.com/terms/")!) {
                    Label("Terms of Use (EULA)", systemImage: "doc.text")
                }
                .tint(.primary)
                .foregroundStyle(.primary)
            }
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.page.pro")
        .proUpgradePresentation(isPresented: $showingPlans, source: .settings)
        #if os(iOS)
        .manageSubscriptionsSheetCompat(
            isPresented: $showingManageSubscription,
            subscriptionGroupID: VVTermProducts.subscriptionGroupId
        )
        #endif
    }

    private var userState: ProSettingsUserState {
        ProSettingsUserState(snapshot: storeManager.entitlementSnapshot)
    }

    private var usageSection: some View {
        Section("Usage") {
            LabeledContent("Servers") {
                Text(
                    String(
                        format: String(localized: "%lld of %lld used"),
                        Int64(serverManager.servers.count),
                        Int64(serverManager.freeServerLimit)
                    )
                )
                .foregroundStyle(.secondary)
            }

            LabeledContent("Workspaces") {
                Text(
                    String(
                        format: String(localized: "%lld of %lld used"),
                        Int64(serverManager.workspaces.count),
                        Int64(FreeTierLimits.maxWorkspaces)
                    )
                )
                .foregroundStyle(.secondary)
            }

            LabeledContent("Connections") {
                Text(
                    String(
                        format: String(localized: "%lld max"),
                        Int64(FreeTierLimits.maxTabs)
                    )
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    private var featuresSection: some View {
        Section("Features") {
            ProSettingsFeatureRow(
                title: "Servers",
                systemImage: "server.rack",
                value: "Unlimited"
            )
            ProSettingsFeatureRow(
                title: "Workspaces",
                systemImage: "folder",
                value: "Unlimited"
            )
            ProSettingsFeatureRow(
                title: "Connections",
                systemImage: "rectangle.stack",
                value: "Unlimited"
            )
            ProSettingsFeatureRow(
                title: "Custom Environments",
                systemImage: "paintbrush",
                value: "Included"
            )
            ProSettingsFeatureRow(
                title: "iCloud Sync",
                systemImage: "icloud",
                value: "Included"
            )
        }
    }

    private func handlePrimaryAction(_ action: ProSettingsPrimaryAction) {
        switch action {
        case .viewPlans:
            showingPlans = true
        case .manageSubscription:
            openSubscriptionManagement()
        }
    }

    private func openSubscriptionManagement() {
        let route: SubscriptionManagementRoute
        #if os(iOS)
        if #available(iOS 17.0, *) {
            route = .resolve(nativeSheetAvailable: true)
        } else {
            route = .resolve(nativeSheetAvailable: false)
        }
        #else
        route = .resolve(nativeSheetAvailable: false)
        #endif

        switch route {
        case .nativeSheet:
            showingManageSubscription = true
        case .web(let url):
            openURL(url)
        }
    }
}

private struct ProSettingsFeatureRow: View {
    let title: LocalizedStringResource
    let systemImage: String
    let value: LocalizedStringResource

    var body: some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

#if os(iOS)
extension View {
    @ViewBuilder
    func manageSubscriptionsSheetCompat(
        isPresented: Binding<Bool>,
        subscriptionGroupID: String
    ) -> some View {
        if #available(iOS 17.0, *) {
            manageSubscriptionsSheet(
                isPresented: isPresented,
                subscriptionGroupID: subscriptionGroupID
            )
        } else {
            self
        }
    }
}
#endif
