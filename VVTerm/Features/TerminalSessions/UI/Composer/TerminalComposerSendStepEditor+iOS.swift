#if os(iOS)
import SwiftUI

struct TerminalComposerSendStepEditor: View {
    @Binding var step: TerminalComposerSendAction.Step

    private enum Kind: CaseIterable, Identifiable {
        case draft, text, shortcut
        var id: Self { self }
        var title: String {
            switch self {
            case .draft: String(localized: "Insert draft")
            case .text: String(localized: "Text")
            case .shortcut: String(localized: "Shortcut")
            }
        }
    }

    private var kind: Binding<Kind> {
        Binding(get: {
            switch step.input {
            case .insertDraft: .draft
            case .text: .text
            case .key: .shortcut
            }
        }, set: { value in
            guard value != kind.wrappedValue else { return }
            switch value {
            case .draft: step.input = .insertDraft
            case .text: step.input = .text("")
            case .shortcut: step.input = .key(.enter, .none)
            }
        })
    }

    private var text: Binding<String> {
        Binding(get: {
            switch step.input {
            case .text(let value): value
            default: ""
            }
        }, set: { value in
            switch step.input {
            case .text: step.input = .text(value)
            default: break
            }
        })
    }

    private var shortcutKey: Binding<TerminalAccessoryShortcutKey> {
        Binding(get: {
            guard case .key(let key, _) = step.input else { return .enter }
            return key
        }, set: { key in
            guard case .key(_, let modifiers) = step.input else { return }
            step.input = .key(key, modifiers)
        })
    }

    private var shortcutModifiers: Binding<TerminalAccessoryShortcutModifiers> {
        Binding(get: {
            guard case .key(_, let modifiers) = step.input else { return .none }
            return modifiers
        }, set: { modifiers in
            guard case .key(let key, _) = step.input else { return }
            step.input = .key(key, modifiers)
        })
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: kind) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            switch step.input {
            case .insertDraft:
                Section { Text("Insert draft includes text and attachments from Chat Mode.") }
            case .text(let value):
                Section {
                    TerminalActionTextEditor(text: text,
                                             accessibilityID: "vvterm.composer.step-text")
                } header: { Text("Content") } footer: {
                    Text(String(format: String(localized: "Text length: %lld/%lld"), Int64(value.count),
                                Int64(TerminalAccessoryProfile.maxCommandContentLength)))
                    Text("Commands send exactly as written.")
                }
            case .key(let key, let modifiers):
                Section {
                    TerminalShortcutFields(
                        key: shortcutKey,
                        modifiers: shortcutModifiers
                    )
                } header: { Text("Shortcut") } footer: {
                    Text(modifiers.displayTitle(for: key.title))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(step.title)
        .navigationBarTitleDisplayMode(.inline)
        .adaptiveSoftScrollEdges()
    }
}
#endif
