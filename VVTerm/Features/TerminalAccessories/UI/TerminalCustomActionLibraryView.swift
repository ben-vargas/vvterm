import SwiftUI

struct TerminalCustomActionLibraryView: View {
    @StateObject private var preferences = TerminalAccessoryPreferencesManager.shared

    @State private var showingCreateSheet = false
    @State private var editingAction: TerminalAccessoryCustomAction?

    var body: some View {
        Form {
            Section {
                if preferences.customActions.isEmpty {
                    Text("No custom actions yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(preferences.customActions) { action in
                        Button {
                            editingAction = action
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(action.title)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(action.kind.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(action.detailText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if action.kind == .command {
                                        Text(action.commandContent.replacingOccurrences(of: "\n", with: " "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Edit") {
                                editingAction = action
                            }
                            .tint(.blue)

                            Button("Delete", role: .destructive) {
                                preferences.deleteCustomAction(id: action.id)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let actions = preferences.customActions
                        for index in offsets {
                            guard actions.indices.contains(index) else { continue }
                            preferences.deleteCustomAction(id: actions[index].id)
                        }
                    }
                }
            } header: {
                Text("Custom Actions")
            } footer: {
                Text(
                    String(
                        format: String(localized: "%lld/%lld custom actions. Tap a row to edit."),
                        Int64(preferences.customActions.count),
                        Int64(TerminalAccessoryProfile.maxCustomActions)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Manage Custom Actions")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!preferences.canCreateCustomAction)
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            TerminalCustomActionFormView()
        }
        .sheet(item: $editingAction) { action in
            TerminalCustomActionFormView(action: action)
        }
    }
}
