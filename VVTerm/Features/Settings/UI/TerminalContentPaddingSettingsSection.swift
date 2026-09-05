import SwiftUI

struct TerminalContentPaddingSettingsSection: View {
    @AppStorage(TerminalDefaults.contentPaddingHorizontalKey)
    private var horizontalPadding = TerminalDefaults.defaultContentPadding
    @AppStorage(TerminalDefaults.contentPaddingVerticalKey)
    private var verticalPadding = TerminalDefaults.defaultContentPadding

    var body: some View {
        Section {
            paddingControl(
                "Horizontal",
                value: horizontalPaddingBinding,
                identifier: "vvterm.settings.contentPadding.horizontal"
            )
            paddingControl(
                "Vertical",
                value: verticalPaddingBinding,
                identifier: "vvterm.settings.contentPadding.vertical"
            )

            Button("Reset to Default") {
                horizontalPadding = TerminalDefaults.defaultContentPadding
                verticalPadding = TerminalDefaults.defaultContentPadding
            }
            .disabled(isDefault)
            .accessibilityIdentifier("vvterm.settings.contentPadding.reset")
        } header: {
            Text("Content Padding")
        } footer: {
            Text("Adds space between the terminal grid and pane edges on this device.")
        }
    }

    private var horizontalPaddingBinding: Binding<Double> {
        Binding(
            get: { TerminalDefaults.clampedContentPadding(horizontalPadding) },
            set: { horizontalPadding = TerminalDefaults.clampedContentPadding($0) }
        )
    }

    private var verticalPaddingBinding: Binding<Double> {
        Binding(
            get: { TerminalDefaults.clampedContentPadding(verticalPadding) },
            set: { verticalPadding = TerminalDefaults.clampedContentPadding($0) }
        )
    }

    private var isDefault: Bool {
        horizontalPadding == TerminalDefaults.defaultContentPadding
            && verticalPadding == TerminalDefaults.defaultContentPadding
    }

    private func paddingControl(
        _ title: LocalizedStringKey,
        value: Binding<Double>,
        identifier: String
    ) -> some View {
        VStack(spacing: 10) {
            LabeledContent(title) {
                Text(pointLabel(for: value.wrappedValue))
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: value,
                in: TerminalDefaults.minimumContentPadding...TerminalDefaults.maximumContentPadding,
                step: TerminalDefaults.contentPaddingStep
            ) {
                Text(title)
            }
            #if os(macOS)
            .labelsHidden()
            #endif
            .accessibilityValue(pointLabel(for: value.wrappedValue))
            .accessibilityIdentifier(identifier)
        }
    }

    private func pointLabel(for value: Double) -> String {
        String(
            format: String(localized: "%lld pt"),
            Int64(TerminalDefaults.clampedContentPadding(value))
        )
    }
}
