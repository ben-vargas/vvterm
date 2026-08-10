//
//  GhosttyTerminalView+iOS.swift
//  VVTerm
//
//  iOS UIView implementation for Ghostty terminal rendering
//

#if os(iOS)
import UIKit
import Metal
import OSLog
import SwiftUI
import IOSurface
import CoreImage
import GameController

enum TerminalSurfaceGeometryUpdate: Equatable {
    case apply
    case preserveCurrentGrid
}

enum TerminalSurfaceGeometryPolicy {
    static func update(
        renderingIsPaused: Bool,
        preservesForegroundKeyboardGrid: Bool,
        currentSize: CGSize,
        proposedSize: CGSize
    ) -> TerminalSurfaceGeometryUpdate {
        if renderingIsPaused {
            return .preserveCurrentGrid
        }
        if preservesForegroundKeyboardGrid,
           abs(proposedSize.width - currentSize.width) < 0.5,
           proposedSize.height > currentSize.height + 0.5 {
            return .preserveCurrentGrid
        }
        return .apply
    }
}

/// UIView that embeds a Ghostty terminal surface with Metal rendering
///
/// This view handles:
/// - Metal layer setup for terminal rendering (Ghostty handles this internally)
/// - Touch and keyboard input
/// - Surface lifecycle management
@MainActor
class GhosttyTerminalView: UIView {
    static let textInputContextID = "app.vivy.VVTerm.GhosttyTerminalView"
    private static let imeProxyOffscreenFrame = CGRect(x: -10_000, y: -10_000, width: 1, height: 1)
    // MARK: - Properties

    var ghosttyApp: ghostty_app_t?
    weak var ghosttyAppWrapper: Ghostty.App?
    internal var surface: Ghostty.Surface?
    var surfaceReference: Ghostty.SurfaceReference?
    let worktreePath: String
    let paneId: String?
    let initialCommand: String?
    let useCustomIO: Bool
    private(set) var terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot
    private(set) var keyboardToolbar: TerminalInputAccessoryView?

    /// Callback invoked when the terminal process exits
    var onProcessExit: (() -> Void)?

    /// Callback invoked when the terminal title changes
    var onTitleChange: ((String) -> Void)?

    /// Callback invoked when the terminal reports working directory changes (OSC 7)
    var onPwdChange: ((String) -> Void)?

    /// Callback when the surface has produced its first layout/draw (used to hide loading UI)
    var onReady: (() -> Void)?

    /// Callback invoked when the terminal grid changes (cols, rows).
    /// In custom I/O mode (SSH), the embedder should send a window-change.
    var onResize: ((Int, Int) -> Void)?

    /// Optional UI-layer observer used by the opt-in keyboard viewport policy.
    /// It is called only when the rendered cursor rect changes.
    var onKeyboardAvoidanceCursorRectChange: ((CGRect) -> Void)?
    /// Reports input-accessory host movement independently of software-keyboard
    /// geometry. Floating iPad keyboards can leave this view docked at the
    /// bottom of the screen.
    var onKeyboardAvoidanceAccessoryFrameChange: (() -> Void)?
    var lastKeyboardAvoidanceAccessoryFrame: CGRect?
    var keyboardAvoidancePreservedSurfaceSize: CGSize?
    var keyboardAvoidanceReferenceSurfaceSize: CGSize?
    var tracksKeyboardAvoidanceReferenceSize = false

    /// Callback invoked when a pinch gesture requests terminal pane zoom.
    var onZoomAction: ((TerminalZoomAction) -> TerminalZoomResult?)?

    /// App-owned pane actions invoked by local iPad keyboard shortcuts.
    var onPaneKeyboardShortcut: ((TerminalSplitCommand) -> Void)?

    /// Per-surface presentation overrides used to preserve pane zoom across global config reloads.
    var surfacePresentationOverrides: TerminalPresentationOverrides = .empty

    /// Callback for OSC 9;4 progress reports
    var onProgressReport: ((GhosttyProgressState, Int?) -> Void)?

    /// Callback invoked when the voice input button is tapped
    var onVoiceButtonTapped: (() -> Void)? {
        didSet {
            keyboardToolbar?.onVoice = onVoiceButtonTapped
        }
    }

    @discardableResult
    func triggerVoiceInput() -> Bool {
        guard let onVoiceButtonTapped else { return false }
        onVoiceButtonTapped()
        return true
    }

    @discardableResult
    func sendReturnKey() -> Bool {
        guard canRouteTerminalInput else { return false }
        sendToolbarKey(.enter)
        return true
    }

    /// Optional app-level paste interceptor used for rich clipboard routing.
    var richPasteInterceptor: ((GhosttyTerminalView) -> Bool)?

    /// Callback invoked when custom terminal I/O emits user input.
    var writeCallback: ((Data) -> Void)?

    /// Optional pane/session actions exposed in the iPad pointer contextual menu.
    var terminalContextMenuActions: TerminalContextMenuActions?

    var didSignalReady = false
    var readonly = false
    let clipboardConfirmationQueue = TerminalClipboardConfirmationQueue()
    var presentedClipboardConfirmation: UIAlertController?
    var clipboardConfirmationRetryWorkItem: DispatchWorkItem?
    var clipboardConfirmationRetryCount = 0

    /// Prevent rendering when the view is offscreen or being torn down.
    var isShuttingDown = false
    var isPaused = false
    var preservesForegroundKeyboardGrid = false
    #if DEBUG
    var keyboardUITestSurfaceFocused = false
    var keyboardUITestGridResizeCount = 0
    #endif
    var customIORedrawScheduled = false
    var keyRepeatTimer: DispatchSourceTimer?
    var hardwareKeyRepeatState = TerminalHardwareKeyRepeatState<Ghostty.Input.KeyEvent>()
    #if DEBUG
    var keyboardUITestUsesManualHardwareKeyRepeatClock = false
    #endif

    /// Track last surface size in pixels to avoid redundant resize/draw work.
    var lastPixelSize: CGSize = .zero
    var lastContentScale: CGFloat = 0
    var lastReportedGrid: (cols: Int, rows: Int) = (0, 0)

    var currentTerminalGridSize: (cols: Int, rows: Int)? {
        guard let size = terminalSize() else { return nil }
        let cols = Int(size.columns)
        let rows = Int(size.rows)
        guard cols > 0, rows > 0 else { return nil }
        return (cols, rows)
    }

    var currentTerminalPixelSize: TerminalPixelSize? {
        TerminalPixelSize(size: lastPixelSize)
    }
    var lastKeyboardAvoidanceCursorRect: CGRect?
    /// Cell size in points for row-to-pixel conversion
    var cellSize: CGSize = .zero

    /// Current scrollbar state from Ghostty core
    var scrollbar: Ghostty.Action.Scrollbar?

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm", category: "GhosttyTerminal")
    private static let keyboardLifecycleLoggingEnabled = DebugLogConfiguration.isEnabled("keyboard")
    private static let keyboardLifecycleLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.VivyTerm",
        category: "TerminalKeyboardInput"
    )

    var isScrolling = false
    var isPinchingTerminalZoom = false
    var pinchReferenceScale: CGFloat = 1
    let zoomIndicatorView = TerminalZoomIndicatorView()
    var zoomIndicatorHideWorkItem: DispatchWorkItem?
    var nativeSelectionSnapshot = TerminalNativeTextSnapshot.empty
    var nativeSelectionLifecycle = TerminalNativeSelectionLifecycle()
    var nativeSelectedRange: NSRange? { nativeSelectionLifecycle.selection }
    var nativeSelectionInteractionActive: Bool { nativeSelectionLifecycle.interactionIsActive }
    var prefersNativeSelectionFirstResponder: Bool { nativeSelectionLifecycle.keepsFirstResponder }
    weak var nativeTextInputDelegate: UITextInputDelegate?
    lazy var nativeSelectionTokenizer = UITextInputStringTokenizer(textInput: self)
    var nativeSelectionAffinity: UITextStorageDirection = .forward
    var nativeTextInteraction: UITextInteraction?
    var nativeFindInteraction: UIFindInteraction?
    @available(iOS 16.0, *)
    var nativeFindSession: GhosttyNativeFindSession?
    var ghosttyFindReportedTotal: Int?
    var ghosttyFindReportedSelectedIndex: Int?
    let nativeFindDocumentIdentifier = "terminal"
    let nativeFindOverlay = TerminalNativeFindOverlayView()
    var nativeFindDecorations: [TerminalNativeFindDecoration] = [] {
        didSet {
            updateNativeFindOverlay()
        }
    }
    lazy var directTouchTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDirectTouchTap(_:))
        )
        recognizer.numberOfTapsRequired = 1
        recognizer.numberOfTouchesRequired = 1
        recognizer.cancelsTouchesInView = false
        recognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        return recognizer
    }()
    lazy var directTouchLongPressExclusionRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(target: nil, action: nil)
        recognizer.minimumPressDuration = 0.2
        recognizer.cancelsTouchesInView = false
        recognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        recognizer.delegate = self
        return recognizer
    }()
    lazy var scrollRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGesture(_:))
        )
        recognizer.maximumNumberOfTouches = 1
        recognizer.requiresExclusiveTouchType = false
        recognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        if #available(iOS 13.4, *) {
            recognizer.allowedScrollTypesMask = .all
        }
        return recognizer
    }()
    private lazy var pointerHoverRecognizer: UIHoverGestureRecognizer = {
        UIHoverGestureRecognizer(target: self, action: #selector(handlePointerHover(_:)))
    }()
    lazy var pinchRecognizer: UIPinchGestureRecognizer = {
        let recognizer = UIPinchGestureRecognizer(
            target: self,
            action: #selector(handlePinchGesture(_:))
        )
        recognizer.requiresExclusiveTouchType = false
        recognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        return recognizer
    }()
    var editMenuInteraction: UIEditMenuInteraction?
    weak var terminalTitleEditor: UIAlertController?
    var editMenuPresentation: TerminalEditMenuPresentation = .selection
    var activePointerButton: TerminalPointerButton?

    /// Observer for config reload notifications
    var configReloadObserver: NSObjectProtocol?
    var inputModeObserver: NSObjectProtocol?
    private var hardwareKeyboardObservers: [NSObjectProtocol] = []
    var hasHardwareKeyboardAttached = false

    // MARK: - Text Input (for spacebar cursor control)
    var textInputModel = TerminalTextInputModel()
    var pendingSystemTextInputHardwareKeys: [UIKey] = []
    var suppressIMEProxyCallbacks = false
    var renderedIMEPreeditText: String?
    lazy var imeProxyTextView: TerminalIMEProxyTextView = {
        let textView = TerminalIMEProxyTextView(frame: bounds)
        textView.terminalOwner = self
        textView.backgroundColor = .clear
        textView.isOpaque = false
        textView.isUserInteractionEnabled = true
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        if #available(iOS 17.0, *) {
            textView.inlinePredictionType = .no
        }
        return textView
    }()
    lazy var terminalZoomCommands = makeTerminalZoomKeyCommands(
        action: #selector(handleTerminalZoomCommand(_:))
    )
    lazy var terminalSplitCommands = makeTerminalSplitKeyCommands(
        action: #selector(handleTerminalSplitCommand(_:))
    )
    var hardwarePressesSentToGhostty: [UInt16: Ghostty.Input.KeyEvent] = [:]
    var systemTextInputPresses: Set<UInt16> = []
    var terminalAltOptionKeyCodes: Set<UInt16> = []

    struct HardwarePressResult {
        var forwardedToSystem: Set<UIPress> = []
        var didHandleGhosttyInput = false
    }

    // MARK: - Rendering Components

    let renderingSetup = GhosttyRenderingSetup()


    // MARK: - Initialization

    /// Create a new Ghostty terminal view
    ///
    /// - Parameters:
    ///   - frame: The initial frame for the view
    ///   - worktreePath: Working directory for the terminal session
    ///   - ghosttyApp: The shared Ghostty app instance (C pointer)
    ///   - appWrapper: The Ghostty.App wrapper for surface tracking (optional)
    ///   - paneId: Unique identifier for this pane
    ///   - command: Optional command to run instead of default shell
    ///   - terminalAccessoryInputSnapshot: App-owned keyboard accessory configuration
    ///   - useCustomIO: If true, uses callback backend for custom I/O (SSH clients)
    init(
        frame: CGRect,
        worktreePath: String,
        ghosttyApp: ghostty_app_t,
        appWrapper: Ghostty.App? = nil,
        paneId: String? = nil,
        command: String? = nil,
        terminalAccessoryInputSnapshot: TerminalAccessoryInputSnapshot,
        useCustomIO: Bool = false
    ) {
        self.worktreePath = worktreePath
        self.ghosttyApp = ghosttyApp
        self.ghosttyAppWrapper = appWrapper
        self.paneId = paneId
        self.initialCommand = command
        self.terminalAccessoryInputSnapshot = terminalAccessoryInputSnapshot
        self.useCustomIO = useCustomIO

        // Use a reasonable default size if frame is zero
        let initialFrame = frame.width > 0 && frame.height > 0 ? frame : CGRect(x: 0, y: 0, width: 800, height: 600)
        super.init(frame: initialFrame)
        // The default guide collapses undocked/floating keyboards to the
        // bottom safe area. Track their real frame so stale docked geometry
        // can be rejected during floating/full transitions.
        keyboardLayoutGuide.followsUndockedKeyboard = true

        // Set content scale factor for retina rendering (important before surface
        // creation). Avoid UIScreen.main (stale instance risk on iOS 26); the
        // window's screen scale is applied again in didMoveToWindow.
        self.contentScaleFactor = max(UITraitCollection.current.displayScale, 1)

        setupSurface()
        addSubview(imeProxyTextView)
        zoomIndicatorView.isHidden = true
        zoomIndicatorView.alpha = 0
        zoomIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(zoomIndicatorView)
        NSLayoutConstraint.activate([
            zoomIndicatorView.centerXAnchor.constraint(equalTo: centerXAnchor),
            zoomIndicatorView.centerYAnchor.constraint(equalTo: centerYAnchor),
            zoomIndicatorView.widthAnchor.constraint(greaterThanOrEqualToConstant: TerminalZoomPresentation.indicatorMinimumWidth),
            zoomIndicatorView.heightAnchor.constraint(greaterThanOrEqualToConstant: TerminalZoomPresentation.indicatorMinimumHeight)
        ])
        nativeFindOverlay.frame = bounds
        addSubview(nativeFindOverlay)

        // Setup gesture recognizers with delegate for simultaneous recognition
        directTouchTapRecognizer.delegate = self
        scrollRecognizer.delegate = self
        pinchRecognizer.delegate = self
        directTouchTapRecognizer.require(toFail: directTouchLongPressExclusionRecognizer)
        addGestureRecognizer(directTouchLongPressExclusionRecognizer)

        addGestureRecognizer(directTouchTapRecognizer)
        addGestureRecognizer(scrollRecognizer)
        addGestureRecognizer(pointerHoverRecognizer)
        addGestureRecognizer(pinchRecognizer)
        isUserInteractionEnabled = true

        setupNativeTextSelectionInteractions()
        setupNativeFindInteraction()
        let editMenuInteraction = UIEditMenuInteraction(delegate: self)
        addInteraction(editMenuInteraction)
        self.editMenuInteraction = editMenuInteraction

        setupConfigReloadObservation()
        setupInputModeObservation()
        registerColorSchemeObserver()
        setupHardwareKeyboardObservation()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    isolated deinit {
        cancelClipboardConfirmations()
        cancelTrackedHardwareInput()
        stopSelectionAutoscroll()
        for observer in hardwareKeyboardObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = inputModeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        let wrapper = self.ghosttyAppWrapper
        let ref = self.surfaceReference
        if let wrapper = wrapper, let ref = ref {
            Task { @MainActor in
                wrapper.unregisterSurface(ref)
            }
        }
    }

    /// Explicitly cleanup the terminal before removal from view hierarchy.
    /// Call this in dismantleUIView to ensure proper cleanup.

    // MARK: - Layer Type
    // On iOS, Ghostty adds its own IOSurfaceLayer as a sublayer of the view's
    // existing CALayer. Keep the default layer type to avoid CAMetalLayer
    // interfering with sublayer rendering/compositing.




    // MARK: - UIView Overrides

    var acceptsTerminalInput = true {
        didSet {
            if !acceptsTerminalInput {
                cancelTrackedHardwareInput()
            }
        }
    }
    var keyboardFocusPolicy = TerminalKeyboardFocusPolicy()
    var suppressDirectTouchKeyboardFocusUntil = Date.distantPast
    var suppressAccessoryForMissingSoftwareKeyboard = false
    let hiddenKeyboardInputView = TerminalSuppressedKeyboardInputView()
    #if DEBUG
    enum KeyboardUITestSoftwareKeyboardFailure: Equatable {
        case none
        case untilSessionRebuild
    }

    var keyboardHideRequestCount = 0
    var keyboardInputSessionRebuildCount = 0
    var keyboardInputViewReloadCount = 0
    var keyboardUITestHardwareKeyboardOverride: Bool?
    var keyboardUITestSoftwareKeyboardFailure = KeyboardUITestSoftwareKeyboardFailure.none
    #endif
    var onWindowAttachmentChange: ((Bool) -> Void)?
    /// Reports terminal touches; isFocusTap is true for the plain
    /// tap-to-focus gesture, which also restores a user-hidden keyboard.
    var onTerminalDirectTouch: ((_ isFocusTap: Bool) -> Void)?
    var onKeyboardBrowseModeChange: ((Bool) -> Void)?
    var onKeyboardAccessoryHideRequested: (() -> Void)?
    var onFindNavigatorVisibilityChange: ((Bool) -> Void)?
    var findNavigatorLifecycle = TerminalFindNavigatorLifecycle()

    func keyboardCoordinatorDiagnosticSnapshot() -> TerminalKeyboardCoordinatorDiagnosticSnapshot {
        let keyboardLayoutFrame: CGRect?
        let screenFrame: CGRect?
        if let window {
            let frameInWindow = convert(keyboardLayoutGuide.layoutFrame, to: window)
            keyboardLayoutFrame = window.convert(
                frameInWindow,
                to: window.screen.coordinateSpace
            )
            screenFrame = window.screen.bounds
        } else {
            keyboardLayoutFrame = nil
            screenFrame = nil
        }
        return TerminalKeyboardCoordinatorDiagnosticSnapshot(
            windowAttached: window != nil,
            windowIsKey: window?.isKeyWindow == true,
            sceneActivationState: window?.windowScene.map { String(describing: $0.activationState) } ?? "nil",
            isFirstResponder: isFirstResponder,
            isSoftwareInputActive: isKeyboardTextInputActive,
            keyboardLayoutFrame: keyboardLayoutFrame,
            screenFrame: screenFrame,
            screenIdentifier: window.map { ObjectIdentifier($0.screen) },
            isSoftwareKeyboardSuppressed: shouldSuppressSoftwareKeyboard
        )
    }

    private func keyboardLifecycleDescription() -> String {
        let snapshot = keyboardCoordinatorDiagnosticSnapshot()
        return [
            "terminal=\(ObjectIdentifier(self))",
            "inputResponder=\(ObjectIdentifier(imeProxyTextView))",
            "window=\(window.map { String(describing: ObjectIdentifier($0)) } ?? "nil")",
            snapshot.lifecycleDescription,
            "viewFirstResponder=\(super.isFirstResponder)",
            "canBecome=\(imeProxyTextView.canBecomeFirstResponder)",
            "canResign=\(imeProxyTextView.canResignFirstResponder)",
            "hardware=\(hasHardwareKeyboardAttached)",
            "forced=\(keyboardFocusPolicy.forcesSoftwareKeyboardPresentation)",
            "browse=\(keyboardFocusPolicy.isBrowsing)",
            "softwareSuppressed=\(shouldSuppressSoftwareKeyboard)",
            "accessorySuppressed=\(suppressAccessoryForMissingSoftwareKeyboard)",
            "accessoryAttached=\(keyboardToolbar?.window != nil)",
            "inputView=\(shouldSuppressSoftwareKeyboard ? "policyHidden" : "system")",
            "language=\(imeProxyTextView.textInputMode?.primaryLanguage ?? "nil")",
            "layoutFrame=\(keyboardLayoutGuide.layoutFrame.debugDescription)",
            "bounds=\(bounds.debugDescription)",
            "safeArea=\(safeAreaInsets)",
            "grid=\(lastReportedGrid.cols)x\(lastReportedGrid.rows)",
        ].joined(separator: " ")
    }

    func logKeyboardLifecycle(
        _ event: String,
        result: Bool? = nil,
        detail: String = ""
    ) {
        guard Self.keyboardLifecycleLoggingEnabled else { return }
        let resultDescription = result.map(String.init) ?? "none"
        Self.keyboardLifecycleLogger.info(
            "event=\(event, privacy: .public) result=\(resultDescription, privacy: .public) detail=\(detail, privacy: .public) \(self.keyboardLifecycleDescription(), privacy: .public)"
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imeProxyTextView.frame = bounds
        nativeFindOverlay.frame = bounds
        bringSubviewToFront(nativeFindOverlay)
        bringSubviewToFront(zoomIndicatorView)

        guard !isShuttingDown else { return }

        // Tell Ghostty the new size after the view has laid out.
        sizeDidChange(bounds.size)

    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        let isVisible = (window != nil)
        if !isVisible {
            cancelTrackedHardwareInput()
        }
        isPaused = !isVisible
        if let surface = surface?.unsafeCValue {
            ghostty_surface_set_occlusion(surface, isVisible)
        }
        onWindowAttachmentChange?(isVisible)
        logKeyboardLifecycle("terminal.didMoveToWindow", detail: "attached=\(isVisible)")

        if isVisible {
            updateHardwareKeyboardState(reloadInputViewsIfNeeded: true)
            sizeDidChange(frame.size)
            requestRender()
        }
    }

    // Use trait change registration API (iOS 17+) with fallback
    private func registerColorSchemeObserver() {
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (view: GhosttyTerminalView, _: UITraitCollection) in
                self?.updateColorScheme()
            }
        }
    }

    private func updateColorScheme() {
        guard let surface = surface?.unsafeCValue else { return }
        let scheme: ghostty_color_scheme_e = traitCollection.userInterfaceStyle == .dark
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
        ghostty_surface_set_color_scheme(surface, scheme)
    }

    private func setupHardwareKeyboardObservation() {
        guard hardwareKeyboardObservers.isEmpty else { return }
        let center = NotificationCenter.default
        hardwareKeyboardObservers.append(
            center.addObserver(
                forName: NSNotification.Name.GCKeyboardDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateHardwareKeyboardState(reloadInputViewsIfNeeded: true)
                }
            }
        )
        hardwareKeyboardObservers.append(
            center.addObserver(
                forName: NSNotification.Name.GCKeyboardDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateHardwareKeyboardState(reloadInputViewsIfNeeded: true)
                }
            }
        )
        updateHardwareKeyboardState(reloadInputViewsIfNeeded: false)
    }

    func removeHardwareKeyboardObservers() {
        for observer in hardwareKeyboardObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        hardwareKeyboardObservers.removeAll()
    }

    func refreshHardwareKeyboardAttachmentFromSystem() {
        let hasHardwareKeyboard = detectedHardwareKeyboardAttached
        let previousInputConfiguration = terminalInputConfiguration
        if setHardwareKeyboardAttached(hasHardwareKeyboard) {
            notifyKeyboardBrowseModeChange(
                previousInputConfiguration: previousInputConfiguration
            )
        }
    }

    func updateHardwareKeyboardState(reloadInputViewsIfNeeded: Bool) {
        let hasHardwareKeyboard = detectedHardwareKeyboardAttached
        let previousInputConfiguration = terminalInputConfiguration
        let didChange = setHardwareKeyboardAttached(hasHardwareKeyboard)
        if didChange {
            logKeyboardLifecycle(
                "hardware.changed",
                detail: "attached=\(hasHardwareKeyboard) vendor=\(GCKeyboard.coalesced?.vendorName ?? "nil")"
            )
        }
        if didChange {
            notifyKeyboardBrowseModeChange(
                previousInputConfiguration: previousInputConfiguration
            )
        }
        if hasHardwareKeyboard {
            focusForHardwareKeyboardIfNeeded()
        } else if didChange {
            if isTerminalTextInputActive, isTextInputSessionEligible, !isFindNavigatorActive {
                _ = requestKeyboardFocus(for: .initialActivation)
            }
        }
        if reloadInputViewsIfNeeded,
           previousInputConfiguration == terminalInputConfiguration,
           isTerminalTextInputActive,
           isTextInputSessionEligible {
            reloadTerminalInputViewsIfActive()
        }
    }

    @discardableResult
    func setHardwareKeyboardAttached(_ attached: Bool) -> Bool {
        guard attached != hasHardwareKeyboardAttached else { return false }
        if !attached {
            cancelTrackedHardwareInput()
        }
        hasHardwareKeyboardAttached = attached
        return true
    }

    func markHardwareKeyboardDetectedFromKeyPress() {
        #if DEBUG
        if keyboardUITestHardwareKeyboardOverride == false { return }
        #endif
        guard !hasHardwareKeyboardAttached else { return }
        let previousInputConfiguration = terminalInputConfiguration
        hasHardwareKeyboardAttached = true
        notifyKeyboardBrowseModeChange(
            previousInputConfiguration: previousInputConfiguration
        )
        focusForHardwareKeyboardIfNeeded()
    }

    private var detectedHardwareKeyboardAttached: Bool {
        #if DEBUG
        if let keyboardUITestHardwareKeyboardOverride {
            return keyboardUITestHardwareKeyboardOverride
        }
        #endif
        return GCKeyboard.coalesced != nil
    }

    // MARK: - Touch Input

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if handleIndirectPointerTouchesBegan(touches, event: event) {
            return
        }
        let location = touches.first?.location(in: self)
        if nativeSelectionLifecycle.interactionIsActive {
            return
        }
        if nativeSelectionLifecycle.keepsFirstResponder {
            if let location, isPointOnNativeSelectionHandleHitArea(location) {
                return
            }
            clearNativeSelectionStateForTerminalInput()
            guard shouldAutoFocusKeyboard(for: touches) else { return }
            notifyDirectTouchOnTerminal(isFocusTap: true)
            requestKeyboardFocus(for: .directTouch)
            return
        }
        // Tap just focuses keyboard - no mouse events (avoids accidental selection).
        notifyDirectTouchOnTerminal(isFocusTap: true)
        requestKeyboardFocus(for: .directTouch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        if handleIndirectPointerTouchesMoved(touches, event: event) {
            return
        }
        // Pan gesture handles scrolling, long press handles selection
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        _ = handleIndirectPointerTouchesEnded(touches, event: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        _ = handleIndirectPointerTouchesEnded(touches, event: event)
    }


    // MARK: - Scroll Gesture

    /// Scroll speed multiplier for iOS touch scrolling
    static let scrollMultiplier: Double = 1.5
    static let selectionAutoscrollEdgeInset: Double = 56
    static let selectionAutoscrollMaximumDelta: Double = 12

    /// Momentum deceleration rate (0.0-1.0, higher = slower deceleration)
    static let momentumDeceleration: Double = 0.92

    /// Minimum velocity to trigger momentum scrolling
    static let minimumMomentumVelocity: Double = 50.0

    /// Display link for momentum animation
    var momentumDisplayLink: CADisplayLink?
    var momentumVelocity: CGPoint = .zero
    var momentumPhase: Ghostty.Input.Momentum = .none
    var selectionAutoscrollDisplayLink: CADisplayLink?
    var selectionAutoscrollLocation: CGPoint?
    var selectionAutoscrollMods: Ghostty.Input.Mods = []



    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            guard allowsHostTextSelection else { return false }
            if let nativeSelectedRange, nativeSelectedRange.length > 0 {
                return true
            }
            guard let cSurface = surface?.unsafeCValue else { return false }
            return ghostty_surface_has_selection(cSurface)
        case #selector(selectAll(_:)):
            guard allowsHostTextSelection else { return false }
            return nativeSelectionSnapshot.length > 0 || selectionGridMetrics() != nil
        case #selector(find(_:)):
            return true
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            if #available(iOS 16.0, *) {
                return nativeFindInteraction?.isFindNavigatorVisible == true
            }
            return false
        case #selector(useSelectionForFind(_:)):
            guard allowsHostTextSelection else { return false }
            return normalizedSelectionMenuText() != nil
        case #selector(paste(_:)):
            return true
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    @objc override func copy(_ sender: Any?) {
        guard let selectionText = currentSelectionText(), !selectionText.isEmpty else { return }
        copyTextToClipboard(selectionText)
    }

    @objc override func selectAll(_ sender: Any?) {
        selectAllVisibleText()
    }

    @objc override func paste(_ sender: Any?) {
        performPasteAction()
    }

    @objc override func find(_ sender: Any?) {
        showFindNavigator()
    }

    @objc override func useSelectionForFind(_ sender: Any?) {
        showFindNavigator(prefillingSelectedText: true)
    }

    @objc override func findNext(_ sender: Any?) {
        guard #available(iOS 16.0, *) else { return }
        nativeFindInteraction?.findNext()
    }

    @objc override func findPrevious(_ sender: Any?) {
        guard #available(iOS 16.0, *) else { return }
        nativeFindInteraction?.findPrevious()
    }


    // MARK: - Software Keyboard (UIKeyInput)

    // MARK: - Keyboard Input (Hardware Keyboard)

    func handleIMEProxyInsertText(_ text: String, fromIMEComposition: Bool = false) -> Bool {
        guard canRouteTerminalInput else { return true }
        if fromIMEComposition {
            cancelTrackedHardwareInput()
        }
        if isNativeSelectionTextInputContext {
            clearNativeSelectionStateForTerminalInput()
        }

        let normalized = text.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty else { return true }
        if let key = terminalKey(forKeyCommandInput: normalized) {
            sendToolbarKey(key)
            return true
        }
        if normalized.hasPrefix("UIKeyInput") {
            return true
        }

        if !fromIMEComposition,
           let key = consumePendingSystemTextInputHardwareKey(),
           sendInterpretedHardwareKeyText(normalized, for: key) {
            invalidateLocalTextInputSession()
            return true
        }
        if !fromIMEComposition, updateActiveInterpretedHardwareKeyRepeat(text: normalized) {
            return true
        }

        let mods = keyboardToolbar?.consumeModifiers() ?? (ctrl: false, alt: false, command: false, shift: false)
        if mods.command {
            var splitModifiers: TerminalSplitShortcutModifiers = [.command]
            if mods.ctrl { splitModifiers.insert(.control) }
            if mods.alt { splitModifiers.insert(.alternate) }
            if mods.shift { splitModifiers.insert(.shift) }
            if let firstCharacter = normalized.first,
               ghosttyKeyMapping(for: firstCharacter)?.requiresShift == true {
                splitModifiers.insert(.shift)
            }
            if performTerminalSplitShortcut(input: normalized, modifiers: splitModifiers) {
                return true
            }
        }
        if mods.ctrl, normalized.compare("v", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame,
           interceptRichPasteIfNeeded() {
            invalidateLocalTextInputSession()
            return true
        }
        if normalized == "\n" || normalized == "\r" {
            commitIMEProxyMarkedTextIfNeeded()
            sendToolbarGhosttyKey(.enter, mods: imeProxyGhosttyModifiers(from: mods))
            return true
        }
        if normalized == "\t" {
            commitIMEProxyMarkedTextIfNeeded()
            sendToolbarGhosttyKey(.tab, mods: imeProxyGhosttyModifiers(from: mods))
            return true
        }

        guard mods.ctrl || mods.alt || mods.command else {
            // Plain text goes into the persistent local document; the text input
            // model reconciles it with the terminal by sending the delta.
            imeProxyTextView.insertCommittedText(normalized)
            return true
        }
        guard let firstChar = normalized.first else { return true }

        if let mapping = ghosttyKeyMapping(for: firstChar) {
            var ghostMods: Ghostty.Input.Mods = []
            if mods.ctrl { ghostMods.insert(.ctrl) }
            if mods.alt { ghostMods.insert(.alt) }
            if mods.command { ghostMods.insert(.super) }
            if mods.shift || mapping.requiresShift { ghostMods.insert(.shift) }
            let keyText = mods.ctrl || mods.alt || mods.command ? nil : mapping.text
            sendModifiedKey(mapping.key, mods: ghostMods, text: keyText, unshiftedCodepoint: mapping.codepoint)
        } else {
            if mods.command {
                return true
            }
            var data = Data()
            if mods.alt {
                data.append(0x1B)
            }
            if mods.ctrl, let controlChar = TerminalControlKey.controlCharacter(for: firstChar) {
                data.append(contentsOf: String(controlChar).utf8)
            } else {
                data.append(contentsOf: String(firstChar).utf8)
            }
            sendAnsiSequence(data)
        }

        if normalized.count > 1 {
            sendText(String(normalized.dropFirst()))
        }
        return true
    }

    private func imeProxyGhosttyModifiers(from mods: (ctrl: Bool, alt: Bool, command: Bool, shift: Bool)) -> Ghostty.Input.Mods {
        var ghostMods: Ghostty.Input.Mods = []
        if mods.ctrl { ghostMods.insert(.ctrl) }
        if mods.alt { ghostMods.insert(.alt) }
        if mods.command { ghostMods.insert(.super) }
        if mods.shift { ghostMods.insert(.shift) }
        return ghostMods
    }

    private func commitIMEProxyMarkedTextIfNeeded() {
        guard imeProxyMarkedRange() != nil else { return }
        withSuppressedIMEProxyCallbacks {
            imeProxyTextView.unmarkText()
        }
        syncTextInputModelFromIMEProxy()
    }

    func sendKeyPress(_ key: Ghostty.Input.Key) {
        guard canRouteTerminalInput else { return }
        guard let surface = surface else { return }
        surface.sendKeyEvent(.init(key: key, action: .press))
        surface.sendKeyEvent(.init(key: key, action: .release))
        requestRender()
    }

    private func sendControlByte(_ value: UInt8) {
        guard canRouteTerminalInput else { return }
        invalidateLocalTextInputSession()
        let scalar = UnicodeScalar(value)
        sendText(String(Character(scalar)))
    }

    private func sendAnsiSequence(_ data: Data) {
        guard canRouteTerminalInput else { return }
        invalidateLocalTextInputSession()
        let text = String(decoding: data, as: UTF8.self)
        sendText(text)
    }

    func sendModifiedKey(
        _ key: Ghostty.Input.Key,
        mods: Ghostty.Input.Mods,
        text: String? = nil,
        unshiftedCodepoint: UInt32 = 0,
        invalidateLocalSession: Bool = true
    ) {
        guard canRouteTerminalInput else { return }
        guard let surface = surface else { return }
        if invalidateLocalSession {
            invalidateLocalTextInputSession()
        }
        let consumedMods = TerminalKeyInputModifierPolicy.consumedModifiers(for: mods)
        let press = Ghostty.Input.KeyEvent(
            key: key,
            action: .press,
            text: text,
            composing: false,
            mods: mods,
            consumedMods: consumedMods,
            unshiftedCodepoint: unshiftedCodepoint
        )
        surface.sendKeyEvent(press)
        let release = Ghostty.Input.KeyEvent(
            key: key,
            action: .release,
            text: nil,
            composing: false,
            mods: mods,
            consumedMods: consumedMods,
            unshiftedCodepoint: unshiftedCodepoint
        )
        surface.sendKeyEvent(release)
        requestRender()
    }

    private func sendControlShortcut(_ char: Character) {
        let lower = String(char).lowercased()
        if let key = Ghostty.Input.Key(rawValue: lower) {
            let codepoint = lower.unicodeScalars.first?.value ?? 0
            sendModifiedKey(key, mods: [.ctrl], text: lower, unshiftedCodepoint: codepoint)
            return
        }
        if let controlChar = TerminalControlKey.controlCharacter(for: char) {
            sendText(String(controlChar))
        }
    }

    /// Send a special key to the terminal
    func sendSpecialKey(_ key: TerminalSpecialKey) {
        guard surface != nil else { return }
        let shouldInvalidateSession: Bool = switch key {
        case .arrowLeft, .arrowRight, .home, .end, .escape:
            false
        default:
            true
        }
        if shouldInvalidateSession {
            invalidateLocalTextInputSession()
        }

        switch key {
        case .enter:
            sendControlByte(0x0D)
            return
        case .backspace:
            // DEL (0x7F) is the typical backspace for terminals.
            sendControlByte(0x7F)
            return
        default:
            break
        }

        let escapeSequence = TerminalSpecialKeySequence.escapeSequence(for: key)
        sendText(escapeSequence)
    }

    /// Send control key combination (e.g., Ctrl+C)
    func sendControlKey(_ char: Character) {
        guard surface != nil else { return }
        if let controlChar = TerminalControlKey.controlCharacter(for: char) {
            sendText(String(controlChar))
        }
    }

}

// MARK: - Terminal Key Enum

indirect enum TerminalKey {
    case escape, tab, enter, backspace, delete, insert
    case arrowUp, arrowDown, arrowLeft, arrowRight
    case home, end, pageUp, pageDown
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case ctrlC, ctrlD, ctrlZ, ctrlL, ctrlA, ctrlE, ctrlK, ctrlU
    case modified(TerminalKey, mods: Ghostty.Input.Mods)

    func withCtrl() -> TerminalKey {
        withModifier(.ctrl)
    }

    func withAlt() -> TerminalKey {
        withModifier(.alt)
    }

    func withShift() -> TerminalKey {
        withModifier(.shift)
    }

    func withCommand() -> TerminalKey {
        withModifier(.super)
    }

    private func withModifier(_ modifier: Ghostty.Input.Mods) -> TerminalKey {
        switch self {
        case .modified(let key, let mods):
            return .modified(key, mods: mods.union(modifier))
        default:
            return .modified(self, mods: modifier)
        }
    }

    var ansiSequence: Data {
        switch self {
        case .escape: return Data([0x1B])
        case .tab: return Data([0x09])
        case .enter: return Data([0x0D])
        case .backspace: return Data([0x7F])
        case .delete: return "\u{1B}[3~".data(using: .utf8)!
        case .insert: return "\u{1B}[2~".data(using: .utf8)!
        case .arrowUp: return "\u{1B}[A".data(using: .utf8)!
        case .arrowDown: return "\u{1B}[B".data(using: .utf8)!
        case .arrowRight: return "\u{1B}[C".data(using: .utf8)!
        case .arrowLeft: return "\u{1B}[D".data(using: .utf8)!
        case .home: return "\u{1B}[H".data(using: .utf8)!
        case .end: return "\u{1B}[F".data(using: .utf8)!
        case .pageUp: return "\u{1B}[5~".data(using: .utf8)!
        case .pageDown: return "\u{1B}[6~".data(using: .utf8)!
        case .f1: return "\u{1B}OP".data(using: .utf8)!
        case .f2: return "\u{1B}OQ".data(using: .utf8)!
        case .f3: return "\u{1B}OR".data(using: .utf8)!
        case .f4: return "\u{1B}OS".data(using: .utf8)!
        case .f5: return "\u{1B}[15~".data(using: .utf8)!
        case .f6: return "\u{1B}[17~".data(using: .utf8)!
        case .f7: return "\u{1B}[18~".data(using: .utf8)!
        case .f8: return "\u{1B}[19~".data(using: .utf8)!
        case .f9: return "\u{1B}[20~".data(using: .utf8)!
        case .f10: return "\u{1B}[21~".data(using: .utf8)!
        case .f11: return "\u{1B}[23~".data(using: .utf8)!
        case .f12: return "\u{1B}[24~".data(using: .utf8)!
        case .ctrlC: return Data([0x03])
        case .ctrlD: return Data([0x04])
        case .ctrlZ: return Data([0x1A])
        case .ctrlL: return Data([0x0C])
        case .ctrlA: return Data([0x01])
        case .ctrlE: return Data([0x05])
        case .ctrlK: return Data([0x0B])
        case .ctrlU: return Data([0x15])
        case .modified(let key, _):
            return key.ansiSequence
        }
    }
}

// MARK: - Keyboard Accessory View

extension GhosttyTerminalView {
    var shouldHideKeyboardAccessoryBar: Bool {
        shouldSuppressSoftwareKeyboard
            || suppressAccessoryForMissingSoftwareKeyboard
    }

    func resolvedInputAccessoryView() -> UIView? {
        guard !isFindNavigatorActive, !shouldHideKeyboardAccessoryBar else {
            return nil
        }
        if keyboardToolbar == nil {
            let toolbar = TerminalInputAccessoryView(
                terminalOwner: self,
                inputSnapshot: terminalAccessoryInputSnapshot,
                onKey: { [weak self] key in
                    self?.handleToolbarKey(key)
                },
                onCustomAction: { [weak self] action in
                    self?.handleToolbarCustomAction(action)
                },
                onVoice: onVoiceButtonTapped,
                onDismissKeyboard: { [weak self] in
                    self?.dismissKeyboardFromToolbar()
                }
            )
            keyboardToolbar = toolbar
        } else {
            keyboardToolbar?.onVoice = onVoiceButtonTapped
        }
        return keyboardToolbar
    }

    func applyTerminalAccessoryInputSnapshot(_ snapshot: TerminalAccessoryInputSnapshot) {
        guard snapshot != terminalAccessoryInputSnapshot else { return }
        terminalAccessoryInputSnapshot = snapshot
        keyboardToolbar?.apply(snapshot)
    }

    func refreshTerminalInputAccessoryAppearance() {
        keyboardToolbar?.refreshAppearance()
    }

    override var inputAccessoryView: UIView? {
        resolvedInputAccessoryView()
    }


    private func handleToolbarKey(_ key: TerminalKey) {
        sendToolbarKey(key)
    }
}

#endif
