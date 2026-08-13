import SwiftUI

struct NavigationStatsSettingsView: View {
    let statsPreferencesStore: PreferencesStore

    @EnvironmentObject private var viewTabConfig: ViewTabConfigurationManager
    @State private var isShowingStatsAppearance = false

    var body: some View {
        Form {
            Section {
                if viewTabConfig.currentVisibleTabs.isEmpty {
                    Text("At least one server view must remain enabled.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewTabConfig.tabOrder) { tab in
                        HStack(spacing: 12) {
                            Label(tab.localizedKey, systemImage: tab.icon)
                                .labelStyle(.titleAndIcon)

                            Spacer(minLength: 8)

                            Toggle("", isOn: visibilityBinding(for: tab.id))
                                .labelsHidden()
                        }
                    }
                    .onMove(perform: viewTabConfig.moveTab)
                }
            } header: {
                HStack {
                    Text("Server Views")
                    Spacer()
                    #if os(iOS)
                    EditButton()
                    #endif
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hide views you do not use. The server selector and Zen mode will only show enabled views.")
                    Text("The default view falls back automatically if it is hidden.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Default View", selection: defaultTabBinding) {
                    ForEach(viewTabConfig.currentVisibleTabs) { tab in
                        Label(tab.localizedKey, systemImage: tab.icon)
                            .tag(tab.id)
                    }
                }
            } header: {
                Text("Default View")
            } footer: {
                Text("This view is shown when a server opens or when a hidden selection needs to fall back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Stats")) {
                Button {
                    isShowingStatsAppearance = true
                } label: {
                    Label(String(localized: "Stats Appearance"), systemImage: "chart.bar.xaxis")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("vvterm.settings.navigationAndStats.statsAppearance")
            }

            Section {
                Button("Reset Server Views") {
                    viewTabConfig.resetToDefaults()
                }
            }
        }
        .statsDetailPresentation(
            isPresented: $isShowingStatsAppearance,
            size: StatsPresentationSize.large
        ) {
            StatsAppearanceSettingsSheet(store: statsPreferencesStore)
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.page.navigationAndStats")
    }

    private func visibilityBinding(for tabID: ConnectionViewTabID) -> Binding<Bool> {
        Binding(
            get: { viewTabConfig.isTabVisible(tabID) },
            set: { viewTabConfig.setVisibility(for: tabID, isVisible: $0) }
        )
    }

    private var defaultTabBinding: Binding<ConnectionViewTabID> {
        Binding(
            get: { viewTabConfig.effectiveDefaultTab() },
            set: { viewTabConfig.setDefaultTab($0) }
        )
    }
}
