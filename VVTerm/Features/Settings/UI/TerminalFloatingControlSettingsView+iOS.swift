#if os(iOS)
import SwiftUI

struct TerminalFloatingControlSettingsView: View {
    @ObservedObject var voiceSettingsStore: VoiceSettingsStore

    @EnvironmentObject private var preferencesStore: TerminalFloatingControlPreferencesStore
    @EnvironmentObject private var storeManager: StoreManager
    @State private var showingProAlert = false
    @State private var actionEditMode: EditMode = .inactive

    private var preferences: TerminalFloatingControlPreferences {
        preferencesStore.preferences
    }

    private var selectedStyle: TerminalFloatingControlPreferences.Style {
        preferences.style
    }

    private var actionLayout: TerminalFloatingControlPreferences.ActionLayout {
        preferences.actionLayout(for: selectedStyle)
            ?? TerminalFloatingControlPreferences.defaultCompactActionLayout
    }

    private var maximumSecondaryActionCount: Int {
        selectedStyle.maximumSecondaryActionCount
    }

    private var styleBinding: Binding<TerminalFloatingControlPreferences.Style> {
        Binding(
            get: { preferences.style },
            set: { style in
                guard style != .radial || storeManager.allowsProFeatures else {
                    showingProAlert = true
                    return
                }
                preferencesStore.setStyle(style)
            }
        )
    }

    private var primaryActionBinding: Binding<TerminalFloatingControlPreferences.Action> {
        Binding(
            get: { actionLayout.primaryAction },
            set: { action in
                guard storeManager.allowsProFeatures else {
                    showingProAlert = true
                    return
                }
                preferencesStore.promoteToPrimary(
                    action,
                    for: selectedStyle
                )
            }
        )
    }

    private var selectedActions: [TerminalFloatingControlPreferences.Action] {
        actionLayout.allActions
    }

    private var unselectedActions: [TerminalFloatingControlPreferences.Action] {
        let selectedActionSet = Set(selectedActions)
        return TerminalFloatingControlPreferences.Action.available.filter {
            !selectedActionSet.contains($0)
        }
    }

    var body: some View {
        Form {
            previewSection
            styleSection
            if selectedStyle != .off {
                primaryActionSection
                secondaryActionsSection
            }
            positionSection
        }
        .environment(\.editMode, $actionEditMode)
        .formStyle(.grouped)
        .navigationTitle("Floating Input Control")
        .adaptiveSoftScrollEdges()
        .proFeatureAlert(
            title: String(localized: "Floating Input Control"),
            message: String(
                localized: "Upgrade to Pro to use Radial Control and customize floating actions."
            ),
            source: .settings,
            isPresented: $showingProAlert
        )
        .onChange(of: selectedStyle) { _ in
            actionEditMode = .inactive
        }
        .accessibilityIdentifier("vvterm.settings.floatingInputControl")
    }

    private var previewSection: some View {
        Section {
            TerminalFloatingControlPreview(
                preferences: preferences,
                hasProAccess: storeManager.allowsProFeatures,
                voiceEnabled: voiceSettingsStore.settings.terminalVoiceButtonEnabled,
                onMove: { horizontalFraction, verticalFraction in
                    preferencesStore.move(
                        toHorizontalFraction: horizontalFraction,
                        verticalFraction: verticalFraction
                    )
                },
                onHide: { side, verticalFraction in
                    preferencesStore.hide(
                        on: side,
                        verticalFraction: verticalFraction
                    )
                },
                onShow: {
                    preferencesStore.show()
                }
            )
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            Text("Preview")
        }
    }

    private var styleSection: some View {
        Section {
            Picker("Style", selection: styleBinding) {
                ForEach(TerminalFloatingControlPreferences.Style.allCases) { style in
                    HStack(spacing: 5) {
                        Text(style.displayTitle)
                            .accessibilityIdentifier(
                                "vvterm.settings.floatingInputControl.style.\(style.rawValue)"
                            )
                        if style == .radial && !storeManager.allowsProFeatures {
                            proText
                        }
                    }
                    .tag(style)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Style")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if selectedStyle == .radial && !storeManager.allowsProFeatures {
                    Text("Compact Buttons is active until Pro is restored.")
                }
                if selectedStyle != .off,
                   actionLayout.primaryAction == .voiceInput,
                   !voiceSettingsStore.settings.terminalVoiceButtonEnabled {
                    Text("The primary button opens the keyboard while Voice Input is off.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var primaryActionSection: some View {
        Section {
            Picker("Primary Action", selection: primaryActionBinding) {
                ForEach(selectedActions) { action in
                    Text(action.displayTitle).tag(action)
                }
            }
        } header: {
            proHeader("Primary Action")
        } footer: {
            Text("The primary action uses the main button.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var secondaryActionsSection: some View {
        Section {
            if actionLayout.secondaryActions.isEmpty {
                Text("No secondary actions")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(
                    Array(actionLayout.secondaryActions.enumerated()),
                    id: \.element
                ) { index, _ in
                    actionPicker(index: index)
                }
                .onDelete(perform: removeActions)
                .onMove(perform: moveActions)
                .deleteDisabled(!storeManager.allowsProFeatures)
                .moveDisabled(!storeManager.allowsProFeatures)
            }

            if actionLayout.secondaryActions.count < maximumSecondaryActionCount {
                addActionControl
            }
        } header: {
            secondaryActionsHeader
        } footer: {
            Text(secondaryActionsFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var secondaryActionsHeader: some View {
        HStack(spacing: 5) {
            proHeader("Secondary Actions")
            Spacer()
            if storeManager.allowsProFeatures,
               !actionLayout.secondaryActions.isEmpty {
                Button(actionEditMode == .active ? "Done" : "Edit") {
                    withAnimation {
                        actionEditMode = actionEditMode == .active ? .inactive : .active
                    }
                }
                .textCase(nil)
                .accessibilityIdentifier(
                    "vvterm.settings.floatingInputControl.editActions"
                )
            }
        }
    }

    private var secondaryActionsFooter: String {
        if selectedStyle == .radial {
            return String(
                localized: "Radial Control shows up to seven secondary actions. Use Edit to reorder or remove them. Press and hold a repeatable action to repeat it."
            )
        }
        return String(
            localized: "Compact Buttons shows up to three secondary actions. Use Edit to reorder or remove them. Press and hold a repeatable action to repeat it."
        )
    }

    @ViewBuilder
    private var addActionControl: some View {
        if storeManager.allowsProFeatures {
            Menu {
                ForEach(unselectedActions) { action in
                    Button(action.displayTitle) {
                        addAction(action)
                    }
                }
            } label: {
                Label("Add Action", systemImage: "plus")
            }
        } else {
            Button {
                showingProAlert = true
            } label: {
                Label("Add Action", systemImage: "plus")
            }
        }
    }

    private var positionSection: some View {
        Section {
            if preferences.hiddenSide != nil {
                Button("Show Floating Controls") {
                    preferencesStore.show()
                }
            }
            Button("Reset Position") {
                preferencesStore.resetPosition()
            }
        } header: {
            Text("Position")
        } footer: {
            Text(
                "Drag any button freely. Push it past the left or right edge to hide it. Tap the edge tab to show it again. Its position stays on this device."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var proText: some View {
        Text(verbatim: "(Pro)")
            .foregroundStyle(.secondary)
            .accessibilityLabel("Pro")
    }

    @ViewBuilder
    private func proHeader(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Text(title)
            if !storeManager.allowsProFeatures {
                proText
            }
        }
    }

    private func actionPicker(index: Int) -> some View {
        Picker(selection: actionBinding(at: index)) {
            ForEach(TerminalFloatingControlPreferences.Action.available) { action in
                Text(action.displayTitle)
                    .tag(action)
                    .disabled(
                        selectedActions.contains(action)
                            && selectedAction(at: index) != action
                    )
            }
        } label: {
            Text("Action \(index + 1)")
        }
    }

    private func actionBinding(
        at index: Int
    ) -> Binding<TerminalFloatingControlPreferences.Action> {
        Binding(
            get: { selectedAction(at: index) ?? .keyboard },
            set: { updateAction($0, at: index) }
        )
    }

    private func selectedAction(
        at index: Int
    ) -> TerminalFloatingControlPreferences.Action? {
        guard actionLayout.secondaryActions.indices.contains(index) else { return nil }
        return actionLayout.secondaryActions[index]
    }

    private func updateAction(
        _ action: TerminalFloatingControlPreferences.Action,
        at index: Int
    ) {
        guard storeManager.allowsProFeatures else {
            showingProAlert = true
            return
        }
        preferencesStore.replaceSecondaryAction(
            at: index,
            with: action,
            for: selectedStyle
        )
    }

    private func addAction(_ action: TerminalFloatingControlPreferences.Action) {
        guard storeManager.allowsProFeatures else {
            showingProAlert = true
            return
        }
        guard unselectedActions.contains(action) else { return }
        preferencesStore.addSecondaryAction(
            action,
            for: selectedStyle
        )
    }

    private func removeActions(at offsets: IndexSet) {
        guard storeManager.allowsProFeatures else {
            showingProAlert = true
            return
        }
        preferencesStore.removeSecondaryActions(
            at: offsets,
            for: selectedStyle
        )
    }

    private func moveActions(from offsets: IndexSet, to destination: Int) {
        guard storeManager.allowsProFeatures else {
            showingProAlert = true
            return
        }
        preferencesStore.moveSecondaryActions(
            from: offsets,
            to: destination,
            for: selectedStyle
        )
    }
}
#endif
