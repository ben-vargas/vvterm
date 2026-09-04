#if os(iOS)
import SwiftUI
import UIKit

struct TerminalFloatingInputOverlay: View {
    let selectedView: ConnectionViewTabID
    let isZenModeEnabled: Bool
    let isFloatingControlShownInZen: Bool
    let hasProAccess: Bool
    let terminalIsReady: Bool
    @ObservedObject private var floatingControls: TerminalServerFloatingControlProjection
    @ObservedObject private var keyboardCoordinator: TerminalKeyboardCoordinator
    @ObservedObject private var preferencesStore: TerminalFloatingControlPreferencesStore
    @ObservedObject private var voiceSettingsStore: VoiceSettingsStore
    let audioService: AudioService
    @ObservedObject private var voiceRecordingOperation: VoiceRecordingOperationCoordinator
    let onVoiceToggle: () -> Void
    let onCancelVoice: () -> Void
    let onShowKeyboard: () -> Void
    let onSendReturn: () -> Void
    let onSystemAction: (TerminalAccessorySystemActionID) -> Void

    init(
        selectedView: ConnectionViewTabID,
        isZenModeEnabled: Bool,
        isFloatingControlShownInZen: Bool,
        hasProAccess: Bool,
        terminalIsReady: Bool,
        floatingControls: TerminalServerFloatingControlProjection,
        keyboardCoordinator: TerminalKeyboardCoordinator,
        preferencesStore: TerminalFloatingControlPreferencesStore,
        voiceSettingsStore: VoiceSettingsStore,
        audioService: AudioService,
        voiceRecordingOperation: VoiceRecordingOperationCoordinator,
        onVoiceToggle: @escaping () -> Void,
        onCancelVoice: @escaping () -> Void,
        onShowKeyboard: @escaping () -> Void,
        onSendReturn: @escaping () -> Void,
        onSystemAction: @escaping (TerminalAccessorySystemActionID) -> Void
    ) {
        self.selectedView = selectedView
        self.isZenModeEnabled = isZenModeEnabled
        self.isFloatingControlShownInZen = isFloatingControlShownInZen
        self.hasProAccess = hasProAccess
        self.terminalIsReady = terminalIsReady
        _floatingControls = ObservedObject(wrappedValue: floatingControls)
        _keyboardCoordinator = ObservedObject(wrappedValue: keyboardCoordinator)
        _preferencesStore = ObservedObject(wrappedValue: preferencesStore)
        _voiceSettingsStore = ObservedObject(wrappedValue: voiceSettingsStore)
        self.audioService = audioService
        _voiceRecordingOperation = ObservedObject(wrappedValue: voiceRecordingOperation)
        self.onVoiceToggle = onVoiceToggle
        self.onCancelVoice = onCancelVoice
        self.onShowKeyboard = onShowKeyboard
        self.onSendReturn = onSendReturn
        self.onSystemAction = onSystemAction
    }

    private var inputPhase: TerminalFloatingInputPhase {
        TerminalFloatingInputPhase(
            voiceOperationPhase: voiceRecordingOperation.phase,
            voicePresentation: floatingControls.state.voicePresentation
        )
    }

    private var presentation: TerminalFloatingControlPresentationPolicy.Presentation {
        TerminalFloatingControlPresentationPolicy.presentation(
            for: .init(
                isPhone: UIDevice.current.userInterfaceIdiom == .phone,
                isTerminalSelected: selectedView == .terminal,
                hasFocusedPane: floatingControls.state.focusedPaneId != nil,
                keyboardIsUserHidden: keyboardCoordinator.isUserHidden,
                isSoftwareKeyboardVisible: keyboardCoordinator.isSoftwareKeyboardVisible,
                findNavigatorIsVisible: floatingControls.state.findNavigatorIsVisible,
                isZenModeEnabled: isZenModeEnabled,
                isFloatingControlShownInZen: isFloatingControlShownInZen,
                preferences: preferencesStore.preferences,
                hasProAccess: hasProAccess,
                inputPhase: inputPhase
            )
        )
    }

    @ViewBuilder
    var body: some View {
        switch presentation {
        case .hidden:
            EmptyView()
        case .visible(let style):
            TerminalFloatingInputControl(
                style: style,
                preferences: preferencesStore.preferences,
                hasProAccess: hasProAccess,
                voiceEnabled: voiceSettingsStore.settings.terminalVoiceButtonEnabled,
                terminalIsReady: terminalIsReady,
                phase: inputPhase,
                audioService: audioService,
                onVoiceToggle: onVoiceToggle,
                onCancelVoice: onCancelVoice,
                onShowKeyboard: onShowKeyboard,
                onSendReturn: onSendReturn,
                onSystemAction: onSystemAction,
                onMove: preferencesStore.move,
                onHide: preferencesStore.hide,
                onShow: preferencesStore.show,
                onResetPosition: preferencesStore.resetPosition
            )
        }
    }
}
#endif
