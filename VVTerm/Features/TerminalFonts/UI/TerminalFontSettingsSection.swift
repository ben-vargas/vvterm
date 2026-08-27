import SwiftUI

struct TerminalFontSettingsSection: View {
    @Binding var primaryFamily: String
    @Binding var fontSize: Double

    @AppStorage(TerminalDefaults.cjkFontNameKey) private var cjkFamily = ""

    @EnvironmentObject private var catalogStore: TerminalFontCatalogStore
    @EnvironmentObject private var storeManager: StoreManager
    @State private var showingProAlert = false

    var body: some View {
        Section {
            Picker("Family", selection: primaryFamilyBinding) {
                fontGroups(catalogStore.catalog.primaryFamilies(ensuring: primaryFamily))
            }

            Picker(selection: cjkFamilyBinding) {
                Text("System (Default)").tag("")
                fontGroups(catalogStore.catalog.fallbackFamilies(ensuring: cjkFamily))
            } label: {
                HStack(spacing: 6) {
                    Text("CJK Font")
                    ProBadge(compact: true)
                }
            }

            VStack(spacing: 10) {
                LabeledContent("Size") {
                    Text(fontSizeLabel)
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { fontSize },
                        set: { fontSize = $0.rounded() }
                    ),
                    in: TerminalDefaults.minimumFontSize...TerminalDefaults.maximumFontSize,
                    step: TerminalDefaults.fontSizeStep
                ) {
                    Text("Size")
                } minimumValueLabel: {
                    Text(verbatim: "A")
                        .font(.caption2)
                } maximumValueLabel: {
                    Text(verbatim: "A")
                        .font(.title3)
                }
                .accessibilityValue(fontSizeLabel)
            }
        } header: {
            Text("Font")
        } footer: {
            Text("CJK font changes apply to new terminals.")
        }
        .proFeatureAlert(
            title: String(localized: "Font"),
            message: String(localized: "Custom and CJK fonts require Pro."),
            source: .settings,
            isPresented: $showingProAlert
        )
        .onAppear {
            catalogStore.refresh()
        }
    }

    private var primaryFamilyBinding: Binding<String> {
        Binding(
            get: { primaryFamily },
            set: { newValue in
                guard storeManager.allowsProFeatures
                        || !TerminalFontSelectionPolicy.primarySelectionRequiresPro(
                            newValue,
                            catalog: catalogStore.catalog
                        ) else {
                    showingProAlert = true
                    return
                }
                primaryFamily = newValue
            }
        )
    }

    private var cjkFamilyBinding: Binding<String> {
        Binding(
            get: { cjkFamily },
            set: { newValue in
                guard newValue.isEmpty || storeManager.allowsProFeatures else {
                    showingProAlert = true
                    return
                }
                cjkFamily = newValue
            }
        )
    }

    private var fontSizeLabel: String {
        String(format: String(localized: "%lld pt"), Int64(fontSize))
    }

    @ViewBuilder
    private func fontGroups(_ families: [TerminalFontFamily]) -> some View {
        ForEach(TerminalFontFamily.Source.allCases, id: \.self) { source in
            let sourceFamilies = families.filter { $0.source == source }
            if !sourceFamilies.isEmpty {
                Section {
                    ForEach(sourceFamilies) { family in
                        Text(family.name).tag(family.name)
                    }
                } header: {
                    sourceHeader(source)
                }
            }
        }
    }

    @ViewBuilder
    private func sourceHeader(_ source: TerminalFontFamily.Source) -> some View {
        switch source {
        case .builtIn:
            Text("Built-in")
        case .system:
            Text("System")
        case .custom:
            HStack(spacing: 6) {
                Text("Custom")
                ProBadge(compact: true)
            }
        }
    }
}
