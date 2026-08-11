//
//  TerminalSettingsView.swift
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

// MARK: - Terminal Settings View

struct TerminalSettingsView: View {
    @Binding var fontName: String
    @Binding var fontSize: Double

    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("terminalKeyboardDismissButtonEnabled") var terminalKeyboardDismissButtonEnabled = true
    @AppStorage("terminalTmuxEnabledDefault") private var tmuxEnabledDefault = true
    @AppStorage("terminalTmuxStartupBehaviorDefault") private var tmuxStartupBehaviorDefaultRaw = TmuxStartupBehavior.askEveryTime.rawValue

    // Copy settings
    @AppStorage("terminalCopyTrimTrailingWhitespace") private var copyTrimTrailingWhitespace = true
    @AppStorage("terminalCopyCollapseBlankLines") private var copyCollapseBlankLines = false
    @AppStorage("terminalCopyStripShellPrompts") private var copyStripShellPrompts = false
    @AppStorage("terminalCopyFlattenCommands") private var copyFlattenCommands = false
    @AppStorage("terminalCopyRemoveBoxDrawing") private var copyRemoveBoxDrawing = false
    @AppStorage("terminalCopyStripAnsiCodes") private var copyStripAnsiCodes = true

    // Image paste settings
    @AppStorage("terminalImagePasteBehavior") private var imagePasteBehaviorRaw = ImagePasteBehavior.askOnce.rawValue
    @AppStorage(TerminalRemoteClipboardReadPolicy.userDefaultsKey)
    private var remoteClipboardReadPolicyRaw = TerminalRemoteClipboardReadPolicy.defaultValue.rawValue

    // SSH settings
    @AppStorage(SSHRuntimeSettings.keepAliveEnabledKey) private var keepAliveEnabled = true
    @AppStorage(SSHRuntimeSettings.keepAliveIntervalKey) private var keepAliveInterval = 30
    @AppStorage(TerminalDefaults.sshAutoReconnectKey) private var autoReconnect = true

    // Cursor settings
    @AppStorage(TerminalDefaults.cursorStyleKey) private var cursorStyleRaw = TerminalDefaults.defaultCursorStyle.rawValue
    @AppStorage(TerminalDefaults.cursorBlinkKey) private var cursorBlink = TerminalDefaults.defaultCursorBlink
    @AppStorage(TerminalDefaults.optionAsAltModeKey) private var optionAsAltModeRaw = TerminalOptionAsAltMode.none.rawValue

    @EnvironmentObject private var terminalThemeManager: TerminalThemeManager
    @EnvironmentObject private var knownHostSettingsCoordinator: KnownHostSettingsCoordinator
    @Environment(\.colorScheme) private var colorScheme

    @State private var availableFonts: [String] = []
    @State private var showingResetKnownHostsConfirmation = false

    private var themeSelection: TerminalThemeSelection {
        terminalThemeManager.themeSelection
    }

    private var tmuxStartupBehaviorDefaultBinding: Binding<TmuxStartupBehavior> {
        Binding(
            get: { TmuxStartupBehavior(rawValue: tmuxStartupBehaviorDefaultRaw) ?? .askEveryTime },
            set: { tmuxStartupBehaviorDefaultRaw = $0.rawValue }
        )
    }

    private var imagePasteBehavior: ImagePasteBehavior {
        ImagePasteBehavior(rawValue: imagePasteBehaviorRaw) ?? .askOnce
    }

    private var imagePasteBehaviorBinding: Binding<ImagePasteBehavior> {
        Binding(
            get: { imagePasteBehavior },
            set: { behavior in
                imagePasteBehaviorRaw = behavior.rawValue
            }
        )
    }

    private var remoteClipboardReadPolicy: TerminalRemoteClipboardReadPolicy {
        TerminalRemoteClipboardReadPolicy(rawValue: remoteClipboardReadPolicyRaw) ?? .defaultValue
    }

    private var remoteClipboardReadPolicyBinding: Binding<TerminalRemoteClipboardReadPolicy> {
        Binding(
            get: { remoteClipboardReadPolicy },
            set: { remoteClipboardReadPolicyRaw = $0.rawValue }
        )
    }

    private var tmuxStartupBehaviorDefault: TmuxStartupBehavior {
        TmuxStartupBehavior(rawValue: tmuxStartupBehaviorDefaultRaw) ?? .askEveryTime
    }

    private var selectedCursorStyle: TerminalCursorStyle {
        TerminalCursorStyle(rawValue: cursorStyleRaw) ?? TerminalDefaults.defaultCursorStyle
    }

    var optionAsAltModeBinding: Binding<TerminalOptionAsAltMode> {
        Binding(
            get: { TerminalOptionAsAltMode(rawValue: optionAsAltModeRaw) ?? .none },
            set: { optionAsAltModeRaw = $0.rawValue }
        )
    }

    private var cursorPreviewThemeName: String {
        guard themeSelection.usePerAppearanceTheme else {
            return themeSelection.darkThemeName
        }

        switch appearanceMode {
        case "light":
            return themeSelection.lightThemeName
        case "dark":
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
                Slider(value: Binding(
                    get: { fontSize },
                    set: { fontSize = $0.rounded() }
                ), in: 4...32, step: 1)
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
                        CursorStyleOptionView(
                            style: style,
                            isSelected: selectedCursorStyle == style,
                            blinks: cursorBlink,
                            palette: cursorPreviewPalette
                        )
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            cursorStyleRaw = style.rawValue
                        }
                        .accessibilityLabel(style.displayName)
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

    private var sessionPersistenceSection: some View {
        Section {
            Toggle("Enable tmux by default", isOn: $tmuxEnabledDefault)

            if tmuxEnabledDefault {
                Picker("On connect", selection: tmuxStartupBehaviorDefaultBinding) {
                    ForEach(TmuxStartupBehavior.configCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }

                Text(tmuxStartupBehaviorDefault.descriptionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Session Persistence")
        } footer: {
            Text("Choose the default behavior for new servers. You can still override per server in server settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var copyProcessingSection: some View {
        Section {
            Toggle("Trim trailing whitespace", isOn: $copyTrimTrailingWhitespace)
            Toggle("Collapse multiple blank lines", isOn: $copyCollapseBlankLines)
            Toggle("Strip shell prompts ($ #)", isOn: $copyStripShellPrompts)
            Toggle("Flatten multi-line commands", isOn: $copyFlattenCommands)
            Toggle("Remove box-drawing characters", isOn: $copyRemoveBoxDrawing)
            Toggle("Strip ANSI escape codes", isOn: $copyStripAnsiCodes)
        } header: {
            Text("Copy Text Processing")
        } footer: {
            Text("Transformations applied when copying text from terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var richClipboardSection: some View {
        Section {
            Picker("Behavior", selection: imagePasteBehaviorBinding) {
                Text(ImagePasteBehavior.automatic.settingsTitle)
                    .tag(ImagePasteBehavior.automatic)
                Text(ImagePasteBehavior.askOnce.settingsTitle)
                    .tag(ImagePasteBehavior.askOnce)
                Text(ImagePasteBehavior.disabled.settingsTitle)
                    .tag(ImagePasteBehavior.disabled)
            }
            .pickerStyle(.menu)
        } header: {
            Text("Image Paste")
        } footer: {
            Text(imagePasteSectionFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var remoteClipboardSection: some View {
        Section {
            Picker("Remote Clipboard Reads", selection: remoteClipboardReadPolicyBinding) {
                ForEach(TerminalRemoteClipboardReadPolicy.allCases) { policy in
                    Text(policy.settingsTitle).tag(policy)
                }
            }
            .pickerStyle(.menu)

            if remoteClipboardReadPolicy == .allow {
                Label("Remote programs can read clipboard data without asking.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Remote Clipboard")
        } footer: {
            Text(remoteClipboardReadPolicy.settingsDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var imagePasteSectionFooter: String {
        switch imagePasteBehavior {
        case .disabled:
            return String(localized: "Image paste is turned off.")
        case .askOnce:
            return String(localized: "You’ll be asked before the image is uploaded.")
        case .automatic:
            return String(localized: "Images upload right away without showing the confirmation sheet.")
        }
    }

    private var sshConnectionSection: some View {
        Section("SSH Connection") {
            Toggle("Auto-reconnect on disconnect", isOn: $autoReconnect)
            Toggle("Send keep-alive packets", isOn: $keepAliveEnabled)

            if keepAliveEnabled {
                Stepper("Interval: \(keepAliveInterval)s", value: $keepAliveInterval, in: 10...120, step: 10)
            }
        }
    }

    private var dangerZoneSection: some View {
        Section {
            Button(role: .destructive) {
                showingResetKnownHostsConfirmation = true
            } label: {
                Label("Reset Trusted SSH Hosts", systemImage: "trash")
                    .foregroundStyle(.red)
            }
            .tint(.red)
            .disabled(knownHostSettingsCoordinator.knownHostCount == 0)
        } header: {
            Text("Danger Zone")
        } footer: {
            Text(knownHostsFooterText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var knownHostsFooterText: String {
        let count = Int64(knownHostSettingsCoordinator.knownHostCount)
        if count == 1 {
            return String(localized: "VVTerm has 1 trusted SSH host on this device. Resetting trusted hosts makes VVTerm trust the host key presented on the next connection.")
        }
        return String(format: String(localized: "VVTerm has %lld trusted SSH hosts on this device. Resetting trusted hosts makes VVTerm trust the host key presented on the next connection."), count)
    }

    var body: some View {
        Form {
            fontSection
            cursorSection
            TerminalThemeSettingsSection()
            terminalBehaviorSection
            keyboardAccessorySection
            sessionPersistenceSection
            copyProcessingSection
            richClipboardSection
            remoteClipboardSection
            sshConnectionSection
            dangerZoneSection
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
        .alert("Reset Trusted SSH Hosts", isPresented: $showingResetKnownHostsConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                knownHostSettingsCoordinator.removeAllKnownHosts()
            }
        } message: {
            Text("VVTerm will forget all saved SSH host fingerprints on this device. The next connection to each host will trust the key it presents.")
        }
        .onAppear {
            if availableFonts.isEmpty {
                availableFonts = Self.fontListEnsuringCurrentFont(
                    systemFonts: loadSystemFonts(),
                    currentFontName: fontName
                )
            }
            knownHostSettingsCoordinator.loadCount()
        }
    }

    /// Ensures the current primary font appears in the picker list.
    /// If the stored font name is missing from the system font list
    /// (e.g., a previously-installed font was removed), it is prepended
    /// so the Picker can display the current selection without breaking.
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
