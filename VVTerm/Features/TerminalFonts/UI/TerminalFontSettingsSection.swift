import SwiftUI

struct TerminalFontSettingsSection: View {
    private enum PickerRole {
        case primary
        case cjk
    }

    @Binding var fontSize: Double

    @EnvironmentObject private var fontStore: TerminalFontStore
    @EnvironmentObject private var storeManager: StoreManager
    #if os(macOS)
    @State private var showingCustomFonts = false
    #endif

    var body: some View {
        Section {
            Picker("Family", selection: primaryFamilyBinding) {
                fontGroups(
                    fontStore.catalog.availableFamilies(
                        ensuring: fontStore.preference.primaryFamily
                    ),
                    role: .primary
                )
            }
            .accessibilityIdentifier("vvterm.settings.appearance.primaryFont")

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
                #if os(macOS)
                .labelsHidden()
                #endif
                .accessibilityIdentifier("vvterm.settings.appearance.fontSize")
                .accessibilityValue(fontSizeLabel)
            }

            Picker(selection: cjkFamilyBinding) {
                Text("Automatic").tag("")
                fontGroups(
                    fontStore.catalog.availableFamilies(
                        ensuring: fontStore.preference.cjkFamily ?? ""
                    ),
                    role: .cjk
                )
            } label: {
                Text("CJK Font")
            }
            .accessibilityIdentifier("vvterm.settings.appearance.cjkFont")

            customFontsControl
        } header: {
            Text("Font")
        } footer: {
            Text("Automatic uses the primary font and standard fallback fonts.")
        }
        #if os(macOS)
        .sheet(isPresented: $showingCustomFonts) {
            CustomFontLibraryView {
                showingCustomFonts = false
            }
        }
        #endif
        .onAppear {
            fontStore.refreshCatalog()
        }
    }

    private var primaryFamilyBinding: Binding<String> {
        Binding(
            get: { fontStore.preference.primaryFamily },
            set: { newValue in
                updateSelection {
                    try fontStore.selectPrimaryFamily(
                        newValue,
                        allowsProFeatures: storeManager.allowsProFeatures
                    )
                }
            }
        )
    }

    private var cjkFamilyBinding: Binding<String> {
        Binding(
            get: { fontStore.preference.cjkFamily ?? "" },
            set: { newValue in
                updateSelection {
                    try fontStore.selectCJKFamily(
                        newValue.isEmpty ? nil : newValue,
                        allowsProFeatures: storeManager.allowsProFeatures
                    )
                }
            }
        )
    }

    private func updateSelection(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            fontStore.refreshCatalog()
        }
    }

    private var fontSizeLabel: String {
        String(format: String(localized: "%lld pt"), Int64(fontSize))
    }

    @ViewBuilder
    private var customFontsControl: some View {
        #if os(iOS)
        NavigationLink {
            CustomFontLibraryView()
        } label: {
            customFontsLabel
        }
        .accessibilityIdentifier("vvterm.settings.appearance.customFonts")
        #else
        Button {
            showingCustomFonts = true
        } label: {
            customFontsLabel
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("vvterm.settings.appearance.customFonts")
        #endif
    }

    private var customFontsLabel: some View {
        HStack(spacing: 10) {
            Text("Custom Fonts")
            Spacer(minLength: 8)
            Text(fontStore.customFonts.count, format: .number)
                .foregroundStyle(.secondary)
            #if os(macOS)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            #endif
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func fontGroups(
        _ families: [TerminalFontFamily],
        role: PickerRole
    ) -> some View {
        ForEach(TerminalFontFamily.Source.allCases, id: \.self) { source in
            let sourceFamilies = families.filter { $0.source == source }
            if !sourceFamilies.isEmpty {
                Section {
                    ForEach(sourceFamilies) { family in
                        let isLocked = isLocked(family, in: role)
                        Text(fontOptionTitle(for: family, isLocked: isLocked))
                            .tag(family.name)
                            .disabled(isLocked)
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
            Text("Custom")
        }
    }

    private func isLocked(
        _ family: TerminalFontFamily,
        in role: PickerRole
    ) -> Bool {
        guard !storeManager.allowsProFeatures else { return false }

        switch role {
        case .primary:
            return TerminalFontSelectionPolicy.requiresProForPrimarySelection(
                family.name,
                catalog: fontStore.catalog
            )
        case .cjk:
            return true
        }
    }

    private func fontOptionTitle(
        for family: TerminalFontFamily,
        isLocked: Bool
    ) -> String {
        guard isLocked else { return family.name }
        return "\(family.name) (\(String(localized: "Pro")))"
    }
}
