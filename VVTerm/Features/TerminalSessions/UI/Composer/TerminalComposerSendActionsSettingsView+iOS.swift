#if os(iOS)
import SwiftUI

struct TerminalComposerSendActionsSettingsView: View {
    @AppStorage(TerminalComposerSendActions.preferenceKey) private var storedActions = Data()
    @State private var editingAction: TerminalComposerSendAction?
    @State private var deletingAction: TerminalComposerSendAction?
    @State private var saveFailed = false

    var body: some View {
        Group {
            switch Result(catching: { try TerminalComposerSendActions.load(storedActions) }) {
            case .success(let configuration):
                actionList(configuration)
            case .failure:
                Form {
                    Text("Could not read send actions. Reset them in Input Mode settings.")
                    Button("Reset to Defaults") { storedActions = Data() }
                }
            }
        }
        .navigationTitle("Send Actions")
        .navigationBarTitleDisplayMode(.inline)
        .adaptiveSoftScrollEdges()
        .alert("Could not save send actions.", isPresented: $saveFailed) { Button("OK") {} }
    }

    private func actionList(_ configuration: TerminalComposerSendActions) -> some View {
        Form {
            Section {
                Picker("Tap Action", selection: Binding(
                    get: { configuration.actions[0].id },
                    set: { id in
                        var updated = configuration
                        guard let index = updated.actions.firstIndex(where: { $0.id == id }) else { return }
                        updated.actions.insert(updated.actions.remove(at: index), at: 0)
                        save(updated)
                    }
                )) {
                    ForEach(configuration.actions) { action in Text(action.title).tag(action.id) }
                }
                .accessibilityIdentifier("vvterm.composer.primary-action")
            } footer: {
                Text("Tap to run the first action. Touch and hold for all actions. Actions also run when the draft is empty.")
            }
            Section {
                ForEach(configuration.actions) { action in
                    Button { editingAction = action } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(action.title).foregroundStyle(.primary).lineLimit(1)
                                if action.title != action.summary {
                                    Text(action.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            if action.id == configuration.actions.first?.id {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                    .accessibilityLabel("Tap Action")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Edit") { editingAction = action }.tint(.blue)
                        if configuration.actions.count > 1 {
                            Button("Delete", role: .destructive) { deletingAction = action }
                        }
                    }
                }
                .onMove { offsets, destination in
                    var updated = configuration
                    updated.actions.move(fromOffsets: offsets, toOffset: destination)
                    save(updated)
                }
            } header: {
                HStack { Text("Custom Actions"); Spacer(); EditButton().textCase(nil) }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editingAction = TerminalComposerSendAction(steps: [.insertDraft, .key(.enter, .none)])
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add Action")
                .disabled(configuration.actions.count >= 32)
                .accessibilityIdentifier("vvterm.composer.add-action")
            }
        }
        .sheet(item: $editingAction) { action in
            NavigationStack {
                TerminalComposerSendActionEditor(action: action) { edited in
                    var updated = configuration
                    if let index = updated.actions.firstIndex(where: { $0.id == edited.id }) {
                        updated.actions[index] = edited
                    } else {
                        updated.actions.append(edited)
                    }
                    if save(updated) { editingAction = nil }
                }
            }
        }
        .alert("Delete Custom Action?", isPresented: Binding(
            get: { deletingAction != nil }, set: { if !$0 { deletingAction = nil } }
        ), presenting: deletingAction) { action in
            Button("Cancel", role: .cancel) { deletingAction = nil }
            Button("Delete", role: .destructive) {
                var updated = configuration
                updated.actions.removeAll { $0.id == action.id }
                if !updated.actions.isEmpty { save(updated) }
                deletingAction = nil
            }
        } message: { _ in Text("This cannot be undone.") }
    }

    @discardableResult
    private func save(_ configuration: TerminalComposerSendActions) -> Bool {
        do { storedActions = try configuration.encoded(); return true }
        catch { saveFailed = true; return false }
    }
}
#endif
