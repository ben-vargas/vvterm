//
//  TerminalAppearanceSettingsView.swift
//  VVTerm
//

import SwiftUI

private struct CursorStyleOptionView: View {
    let style: TerminalCursorStyle
    let isSelected: Bool
    let blinks: Bool
    let palette: TerminalThemePreviewPalette

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                TerminalCursorPreview(style: style, blinks: blinks, palette: palette)
                    .frame(width: 72, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
            }

            Text(style.displayName)
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .contentShape(Rectangle())
    }
}

private struct TerminalCursorPreview: View {
    let style: TerminalCursorStyle
    let blinks: Bool
    let palette: TerminalThemePreviewPalette

    var body: some View {
        if blinks {
            TimelineView(.periodic(from: .now, by: 0.55)) { timeline in
                previewContent(isVisible: cursorIsVisible(at: timeline.date))
            }
        } else {
            previewContent(isVisible: true)
        }
    }

    private func cursorIsVisible(at date: Date) -> Bool {
        guard blinks else { return true }
        let tick = Int(date.timeIntervalSinceReferenceDate / 0.55)
        return tick.isMultiple(of: 2)
    }

    private func previewContent(isVisible: Bool) -> some View {
        HStack(spacing: 0) {
            Text("~ ")
                .foregroundStyle(palette.foreground.opacity(0.55))
            cursorSample(isVisible: isVisible)
        }
        .font(.system(size: 19, weight: .medium, design: .monospaced))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.foreground.opacity(0.14), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func cursorSample(isVisible: Bool) -> some View {
        switch style {
        case .block:
            Text("A")
                .foregroundStyle(isVisible ? palette.cursorText : palette.foreground.opacity(0.75))
                .padding(.horizontal, 1)
                .background(
                    Rectangle()
                        .fill(isVisible ? palette.cursor : Color.clear)
                )
        case .bar:
            ZStack(alignment: .leading) {
                Text("A")
                    .foregroundStyle(palette.foreground.opacity(0.75))
                Rectangle()
                    .fill(isVisible ? palette.cursor : Color.clear)
                    .frame(width: 2, height: 23)
            }
        case .underline:
            ZStack(alignment: .bottom) {
                Text("A")
                    .foregroundStyle(palette.foreground.opacity(0.75))
                Rectangle()
                    .fill(isVisible ? palette.cursor : Color.clear)
                    .frame(width: 13, height: 2)
            }
        case .blockHollow:
            Text("A")
                .foregroundStyle(palette.foreground.opacity(0.75))
                .padding(.horizontal, 1)
                .overlay(
                    Rectangle()
                        .stroke(isVisible ? palette.cursor : Color.clear, lineWidth: 1.5)
                )
        }
    }
}

struct TerminalAppearanceSettingsView: View {
    @Binding var fontName: String
    @Binding var fontSize: Double

    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue
    @AppStorage(TerminalDefaults.cursorStyleKey) private var cursorStyleRaw = TerminalDefaults.defaultCursorStyle.rawValue
    @AppStorage(TerminalDefaults.cursorBlinkKey) private var cursorBlink = TerminalDefaults.defaultCursorBlink

    @EnvironmentObject private var terminalThemeManager: TerminalThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var availableFonts: [String] = []

    private var themeSelection: TerminalThemeSelection {
        terminalThemeManager.themeSelection
    }

    private var selectedCursorStyle: TerminalCursorStyle {
        TerminalCursorStyle(rawValue: cursorStyleRaw) ?? TerminalDefaults.defaultCursorStyle
    }

    private var cursorPreviewThemeName: String {
        guard themeSelection.usePerAppearanceTheme else {
            return themeSelection.darkThemeName
        }

        switch appearanceMode {
        case AppearanceMode.light.rawValue:
            return themeSelection.lightThemeName
        case AppearanceMode.dark.rawValue:
            return themeSelection.darkThemeName
        default:
            return colorScheme == .dark
                ? themeSelection.darkThemeName
                : themeSelection.lightThemeName
        }
    }

    private var cursorPreviewPalette: TerminalThemePreviewPalette {
        ThemeColorParser.previewPalette(for: cursorPreviewThemeName)
    }

    var body: some View {
        Form {
            fontSection
            cursorSection
            TerminalThemeSettingsSection()
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.page.terminalAppearance")
        .onAppear {
            if availableFonts.isEmpty {
                availableFonts = Self.fontListEnsuringCurrentFont(
                    systemFonts: loadSystemFonts(),
                    currentFontName: fontName
                )
            }
        }
    }

    private var fontSection: some View {
        Section("Font") {
            Picker("Font Family", selection: $fontName) {
                ForEach(availableFonts, id: \.self) { font in
                    Text(font).tag(font)
                }
            }
            .disabled(availableFonts.isEmpty)

            HStack {
                Text(String(format: String(localized: "Size: %lldpt"), Int64(fontSize)))
                    .frame(width: 80, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { fontSize },
                        set: { fontSize = $0.rounded() }
                    ),
                    in: 4...32,
                    step: 1
                )
                Stepper("", value: $fontSize, in: 4...32, step: 1)
                    .labelsHidden()
            }
        }
    }

    private var cursorSection: some View {
        Section("Cursor") {
            VStack(spacing: 16) {
                HStack(spacing: 0) {
                    ForEach(TerminalCursorStyle.allCases) { style in
                        let isSelected = selectedCursorStyle == style
                        Button {
                            cursorStyleRaw = style.rawValue
                        } label: {
                            CursorStyleOptionView(
                                style: style,
                                isSelected: isSelected,
                                blinks: cursorBlink,
                                palette: cursorPreviewPalette
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(style.displayName)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityIdentifier("vvterm.settings.cursor.\(style.rawValue)")
                    }
                }

                Divider()

                HStack {
                    Text("Blink")
                    Spacer()
                    Toggle("Blink", isOn: $cursorBlink)
                        .labelsHidden()
                }
            }
        }
    }

    nonisolated static func fontListEnsuringCurrentFont(
        systemFonts: [String],
        currentFontName: String
    ) -> [String] {
        let trimmed = currentFontName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return systemFonts }
        guard !systemFonts.contains(trimmed) else { return systemFonts }
        return [trimmed] + systemFonts
    }
}
