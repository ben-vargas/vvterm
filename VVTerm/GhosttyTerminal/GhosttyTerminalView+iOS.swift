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

private struct IMEProxySnapshot: Equatable {
    var text: String
    var selectedRange: NSRange
    var markedRange: NSRange?
}

@MainActor
private final class TerminalIMEProxyTextView: UITextView {
    weak var terminalOwner: GhosttyTerminalView?

    override var selectedTextRange: UITextRange? {
        get { super.selectedTextRange }
        set {
            super.selectedTextRange = normalizedSelectedTextRange(newValue)
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        false
    }

    override var canBecomeFirstResponder: Bool {
        terminalOwner?.imeProxyCanBecomeFirstResponder ?? false
    }

    override var inputAccessoryView: UIView? {
        get { terminalOwner?.resolvedInputAccessoryView() }
        set { super.inputAccessoryView = newValue }
    }

    override var textInputContextIdentifier: String? {
        terminalOwner?.currentTextInputContextIdentifier
    }

    override var keyboardType: UIKeyboardType {
        get { .default }
        set { }
    }

    override var keyboardAppearance: UIKeyboardAppearance {
        get { terminalOwner?.resolvedKeyboardAppearance ?? .default }
        set { }
    }

    override var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set { }
    }

    override var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set { }
    }

    override var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set { }
    }

    override var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set { }
    }

    override var smartDashesType: UITextSmartDashesType {
        get { .no }
        set { }
    }

    override var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no }
        set { }
    }

    @available(iOS 17.0, *)
    override var inlinePredictionType: UITextInlinePredictionType {
        get { .no }
        set { }
    }

    override var enablesReturnKeyAutomatically: Bool {
        get { false }
        set { }
    }

    override var returnKeyType: UIReturnKeyType {
        get { .default }
        set { }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        terminalOwner?.imeProxyFocusDidChange(isFocused: result || isFirstResponder)
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        terminalOwner?.imeProxyFocusDidChange(isFocused: isFirstResponder)
        return result
    }

    override func deleteBackward() {
        let before = terminalOwner?.imeProxySnapshot()
        super.deleteBackward()
        terminalOwner?.imeProxyDidDeleteBackward(before: before)
    }

    override func insertText(_ text: String) {
        if terminalOwner?.handleIMEProxyInsertText(text) == true {
            return
        }
        super.insertText(text)
    }

    override func draw(_ rect: CGRect) {
        // The proxy exists only to drive UIKit IME state. Terminal text/preedit is
        // rendered separately, so the proxy itself should stay visually silent.
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        guard super.markedTextRange != nil else { return .zero }
        return terminalOwner?.imeProxyCaretRect(for: position) ?? super.caretRect(for: position)
    }

    override func firstRect(for range: UITextRange) -> CGRect {
        guard super.markedTextRange != nil else { return .zero }
        return terminalOwner?.imeProxyFirstRect(for: range) ?? super.firstRect(for: range)
    }

    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        []
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let terminalOwner else {
            super.pressesBegan(presses, with: event)
            return
        }
        let result = terminalOwner.processHardwarePressesBegan(presses, event: event)
        if !result.forwardedToSystem.isEmpty {
            super.pressesBegan(result.forwardedToSystem, with: event)
        }
        if result.didHandleGhosttyInput {
            terminalOwner.requestRender()
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let terminalOwner else {
            super.pressesEnded(presses, with: event)
            return
        }
        let result = terminalOwner.processHardwarePressesEnded(presses, event: event)
        if !result.forwardedToSystem.isEmpty {
            super.pressesEnded(result.forwardedToSystem, with: event)
        }
        if result.didHandleGhosttyInput {
            terminalOwner.requestRender()
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(presses, with: event)
        terminalOwner?.processHardwarePressesCancelled(presses)
    }

    private func normalizedSelectedTextRange(_ range: UITextRange?) -> UITextRange? {
        guard let range else { return nil }
        guard super.markedTextRange == nil else { return range }

        let start = offset(from: beginningOfDocument, to: range.start)
        let end = offset(from: beginningOfDocument, to: range.end)
        guard end > start else { return range }
        guard let collapsed = position(from: beginningOfDocument, offset: end) else { return range }
        return textRange(from: collapsed, to: collapsed)
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
    private static let textInputContextID = "app.vivy.VVTerm.GhosttyTerminalView"
    private static let imeProxyOffscreenFrame = CGRect(x: -10_000, y: -10_000, width: 1, height: 1)
    // MARK: - Properties

    private var ghosttyApp: ghostty_app_t?
    private weak var ghosttyAppWrapper: Ghostty.App?
    internal var surface: Ghostty.Surface?
    private var surfaceReference: Ghostty.SurfaceReference?
    private let worktreePath: String
    private let paneId: String?
    private let initialCommand: String?
    private let useCustomIO: Bool

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

    /// Callback for OSC 9;4 progress reports
    var onProgressReport: ((GhosttyProgressState, Int?) -> Void)?

    /// Callback invoked when the voice input button is tapped
    var onVoiceButtonTapped: (() -> Void)? {
        didSet {
            keyboardToolbar?.onVoice = onVoiceButtonTapped
        }
    }

    /// Optional app-level paste interceptor used for rich clipboard routing.
    var richPasteInterceptor: ((GhosttyTerminalView) -> Bool)?
    private var didSignalReady = false

    /// Prevent rendering when the view is offscreen or being torn down.
    private var isShuttingDown = false
    private var isPaused = false
    private var customIORedrawScheduled = false
    private var keyRepeatTimer: DispatchSourceTimer?
    private var repeatingHardwareKey: UIKey?
    private var repeatingFallbackKey: Ghostty.Input.Key?
    private var repeatingFallbackModifiers: UIKeyModifierFlags = []
    private var repeatingKeyCode: UInt16?

    /// Track last surface size in pixels to avoid redundant resize/draw work.
    private var lastPixelSize: CGSize = .zero
    private var lastContentScale: CGFloat = 0
    private var lastReportedGrid: (cols: Int, rows: Int) = (0, 0)
    /// Cell size in points for row-to-pixel conversion
    var cellSize: CGSize = .zero

    /// Current scrollbar state from Ghostty core
    var scrollbar: Ghostty.Action.Scrollbar?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm", category: "GhosttyTerminal")

    private var isSelecting = false
    private var isScrolling = false
    private lazy var selectionRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleSelectionPress(_:))
        )
        recognizer.minimumPressDuration = 0.2
        recognizer.allowableMovement = 8
        recognizer.cancelsTouchesInView = true
        return recognizer
    }()

    private lazy var doubleTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTap(_:))
        )
        recognizer.numberOfTapsRequired = 2
        return recognizer
    }()

    private lazy var tripleTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleTripleTap(_:))
        )
        recognizer.numberOfTapsRequired = 3
        return recognizer
    }()

    private lazy var scrollRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePanGesture(_:))
        )
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }()

    private var editMenuInteraction: UIEditMenuInteraction?

    /// Observer for config reload notifications
    private var configReloadObserver: NSObjectProtocol?
    private var hardwareKeyboardObservers: [NSObjectProtocol] = []
    private var hasHardwareKeyboardAttached = false

    // MARK: - Text Input (for spacebar cursor control)
    private var textInputModel = TerminalTextInputModel()
    private var suppressIMEProxyCallbacks = false
    private var renderedIMEPreeditText: String?
    private lazy var imeProxyTextView: TerminalIMEProxyTextView = {
        let textView = TerminalIMEProxyTextView(frame: Self.imeProxyOffscreenFrame, textContainer: nil)
        textView.terminalOwner = self
        textView.delegate = self
        textView.backgroundColor = .clear
        textView.textColor = .clear
        textView.tintColor = .clear
        textView.alpha = 0.01
        textView.isOpaque = false
        textView.isUserInteractionEnabled = true
        textView.isScrollEnabled = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.showsHorizontalScrollIndicator = false
        textView.showsVerticalScrollIndicator = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        if #available(iOS 17.0, *) {
            textView.inlinePredictionType = .no
        }
        textView.inputAssistantItem.leadingBarButtonGroups = []
        textView.inputAssistantItem.trailingBarButtonGroups = []
        return textView
    }()
    private var hardwarePressesSentToGhostty: Set<UInt16> = []
    private var fallbackHardwarePressKeys: [UInt16: Ghostty.Input.Key] = [:]
    private var fallbackHardwarePressModifiers: [UInt16: UIKeyModifierFlags] = [:]
    private var systemTextInputPresses: Set<UInt16> = []

    fileprivate struct HardwarePressResult {
        var forwardedToSystem: Set<UIPress> = []
        var didHandleGhosttyInput = false
    }

    // MARK: - Rendering Components

    private let renderingSetup = GhosttyRenderingSetup()

    fileprivate func requestRender() {
        if isShuttingDown { return }
        if isPaused { return }
        guard surface?.unsafeCValue != nil else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }
        markIOSurfaceLayersForDisplay()
    }

    private func scheduleCustomIORedraw() {
        guard useCustomIO else { return }
        guard !customIORedrawScheduled else { return }
        customIORedrawScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.customIORedrawScheduled = false
            guard !self.isShuttingDown, !self.isPaused else { return }
            guard let surface = self.surface?.unsafeCValue else { return }
            guard self.bounds.width > 0 && self.bounds.height > 0 else { return }

            self.updateContentScaleIfNeeded()
            self.configureIOSurfaceLayers(size: self.bounds.size)
            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
            self.markIOSurfaceLayersForDisplay()
        }
    }

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
    ///   - useCustomIO: If true, uses callback backend for custom I/O (SSH clients)
    init(frame: CGRect, worktreePath: String, ghosttyApp: ghostty_app_t, appWrapper: Ghostty.App? = nil, paneId: String? = nil, command: String? = nil, useCustomIO: Bool = false) {
        self.worktreePath = worktreePath
        self.ghosttyApp = ghosttyApp
        self.ghosttyAppWrapper = appWrapper
        self.paneId = paneId
        self.initialCommand = command
        self.useCustomIO = useCustomIO

        // Use a reasonable default size if frame is zero
        let initialFrame = frame.width > 0 && frame.height > 0 ? frame : CGRect(x: 0, y: 0, width: 800, height: 600)
        super.init(frame: initialFrame)

        // Set content scale factor for retina rendering (important before surface creation)
        self.contentScaleFactor = UIScreen.main.scale

        setupSurface()
        addSubview(imeProxyTextView)

        // Setup gesture recognizers with delegate for simultaneous recognition
        selectionRecognizer.delegate = self
        scrollRecognizer.delegate = self
        doubleTapRecognizer.delegate = self
        tripleTapRecognizer.delegate = self

        // Triple tap should require double tap to fail first
        doubleTapRecognizer.require(toFail: tripleTapRecognizer)

        addGestureRecognizer(selectionRecognizer)
        addGestureRecognizer(scrollRecognizer)
        addGestureRecognizer(doubleTapRecognizer)
        addGestureRecognizer(tripleTapRecognizer)
        isUserInteractionEnabled = true

        // Setup edit menu interaction for copy/paste
        let interaction = UIEditMenuInteraction(delegate: self)
        addInteraction(interaction)
        editMenuInteraction = interaction

        setupConfigReloadObservation()
        registerColorSchemeObserver()
        setupHardwareKeyboardObservation()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        for observer in hardwareKeyboardObservers {
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
    func cleanup() {
        isShuttingDown = true
        isPaused = true
        stopMomentumScrolling()

        // Remove config reload observer
        if let observer = configReloadObserver {
            NotificationCenter.default.removeObserver(observer)
            configReloadObserver = nil
        }
        removeHardwareKeyboardObservers()

        // Clear all callbacks first to prevent any further interactions
        onReady = nil
        onProcessExit = nil
        onTitleChange = nil
        onPwdChange = nil
        onProgressReport = nil
        onResize = nil
        richPasteInterceptor = nil
        writeCallback = nil

        // Stop rendering/input callbacks and mark the surface as not visible.
        if let cSurface = surface?.unsafeCValue {
            ghostty_surface_set_write_callback(cSurface, nil, nil)
            ghostty_surface_set_focus(cSurface, false)
            ghostty_surface_set_occlusion(cSurface, false)
        }

        // Unregister surface from app wrapper synchronously
        if let wrapper = ghosttyAppWrapper, let ref = surfaceReference {
            wrapper.unregisterSurface(ref)
        }
        surfaceReference = nil

        // CRITICAL: Explicitly free the surface to release Metal resources
        // Do not rely on deinit - Task.detached may never run
        surface?.free()
        surface = nil
    }

    /// Pause rendering and input without destroying the surface.
    func pauseRendering() {
        guard !isShuttingDown else { return }
        isPaused = true

        if let surface = surface?.unsafeCValue {
            ghostty_surface_set_focus(surface, false)
            ghostty_surface_set_occlusion(surface, false)
        }
    }

    /// Resume rendering/input after a pause.
    func resumeRendering() {
        guard !isShuttingDown else { return }
        isPaused = false

        if let surface = surface?.unsafeCValue {
            ghostty_surface_set_occlusion(surface, true)
        }

        sizeDidChange(bounds.size)
        requestRender()
    }

    // MARK: - Layer Type
    // On iOS, Ghostty adds its own IOSurfaceLayer as a sublayer of the view's
    // existing CALayer. Keep the default layer type to avoid CAMetalLayer
    // interfering with sublayer rendering/compositing.

    // MARK: - Setup

    /// Create and configure the Ghostty surface
    private func setupConfigReloadObservation() {
        configReloadObserver = NotificationCenter.default.addObserver(
            forName: Ghostty.configDidReloadNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.requestRender()
            }
        }
    }

    private func setupSurface() {
        guard let app = ghosttyApp else {
            Self.logger.error("Cannot create surface: ghostty_app_t is nil")
            return
        }

        guard let cSurface = renderingSetup.setupSurface(
            view: self,
            ghosttyApp: app,
            worktreePath: worktreePath,
            initialBounds: bounds,
            paneId: paneId,
            command: initialCommand,
            useCustomIO: useCustomIO
        ) else {
            return
        }

        // CRITICAL: Configure the IOSurfaceLayer that Ghostty just added as a sublayer.
        // Ghostty's Metal renderer on iOS adds IOSurfaceLayer as a sublayer but doesn't
        // set its frame/contentsScale - we must do it here immediately after creation.
        // Without this, setSurfaceCallback will discard all frames due to size mismatch.
        configureIOSurfaceLayers(size: bounds.size)

        // Wrap in Swift Surface class
        self.surface = Ghostty.Surface(cSurface: cSurface)

        // Register surface with app wrapper for config update tracking
        if let wrapper = ghosttyAppWrapper {
            self.surfaceReference = wrapper.registerSurface(cSurface)
        }

        Self.logger.info("Ghostty surface created, sublayers: \(self.layer.sublayers?.count ?? 0)")
    }

    // MARK: - Size Change Handling (matches official Ghostty iOS pattern)

    /// Notify Ghostty of size changes. This method follows the official Ghostty iOS implementation.
    /// It sets content scale BEFORE size, using the contentScaleFactor.
    /// NOTE: On iOS, we must also configure the IOSurfaceLayer's frame/contentsScale in layoutSubviews
    /// and didMoveToWindow because Ghostty adds it as a sublayer that doesn't auto-resize.
    /// Without proper sublayer configuration, Ghostty's setSurfaceCallback will discard all frames.
    func sizeDidChange(_ size: CGSize) {
        if isShuttingDown { return }
        guard let surface = surface?.unsafeCValue else { return }
        guard size.width > 0 && size.height > 0 else { return }

        updateContentScaleIfNeeded()
        configureIOSurfaceLayers(size: size)

        let scale = self.contentScaleFactor
        let pixelWidth = floor(size.width * scale)
        let pixelHeight = floor(size.height * scale)
        guard pixelWidth > 0 && pixelHeight > 0 else { return }
        let pixelSize = CGSize(width: pixelWidth, height: pixelHeight)

        let sizeChanged = pixelSize != lastPixelSize || scale != lastContentScale
        if sizeChanged {
            lastPixelSize = pixelSize
            lastContentScale = scale

            ghostty_surface_set_content_scale(surface, scale, scale)
            ghostty_surface_set_size(
                surface,
                UInt32(pixelWidth),
                UInt32(pixelHeight)
            )
            reportGridResizeIfNeeded()
        }

        if !isPaused {
            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
            markIOSurfaceLayersForDisplay()
        }

        if !didSignalReady {
            didSignalReady = true
            DispatchQueue.main.async { [weak self] in
                self?.onReady?()
            }
        }
    }

    private func reportGridResizeIfNeeded() {
        guard let size = terminalSize() else { return }
        let cols = Int(size.columns)
        let rows = Int(size.rows)
        guard cols > 0, rows > 0 else { return }
        guard cols != lastReportedGrid.cols || rows != lastReportedGrid.rows else { return }
        lastReportedGrid = (cols, rows)
        onResize?(cols, rows)
    }

    // MARK: - Text Input Helpers

    private func textInputGridMetrics() -> (cols: Int, rows: Int, cellSize: CGSize, length: Int) {
        let cols = max(lastReportedGrid.cols, 1)
        let rows = max(lastReportedGrid.rows, 1)
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        if cellSize.width > 0 {
            cellWidth = cellSize.width
        } else if bounds.width > 0 {
            cellWidth = bounds.width / CGFloat(cols)
        } else {
            cellWidth = 1
        }
        if cellSize.height > 0 {
            cellHeight = cellSize.height
        } else if bounds.height > 0 {
            cellHeight = bounds.height / CGFloat(rows)
        } else {
            cellHeight = 1
        }
        let size = CGSize(width: max(cellWidth, 1), height: max(cellHeight, 1))
        let length = max(cols * rows, 1)
        return (cols, rows, size, length)
    }

    private func textInputDocumentLength() -> Int {
        max(textInputModel.documentLength, (imeProxyTextView.text ?? "").utf16.count)
    }

    private func clampTextInputIndex(_ index: Int) -> Int {
        min(max(index, 0), textInputDocumentLength())
    }

    fileprivate var imeProxyCanBecomeFirstResponder: Bool {
        isTextInputSessionEligible
    }

    fileprivate var currentTextInputContextIdentifier: String? {
        isTextInputSessionEligible ? Self.textInputContextID : nil
    }

    fileprivate var resolvedKeyboardAppearance: UIKeyboardAppearance {
        if #available(iOS 13.0, *) {
            return traitCollection.userInterfaceStyle == .dark ? .dark : .light
        }
        return .default
    }

    fileprivate func imeProxySnapshot() -> IMEProxySnapshot {
        IMEProxySnapshot(
            text: imeProxyTextView.text ?? "",
            selectedRange: imeProxyTextView.selectedRange,
            markedRange: imeProxyMarkedRange()
        )
    }

    private func imeProxyMarkedRange() -> NSRange? {
        guard let range = imeProxyTextView.markedTextRange else { return nil }
        let start = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: range.start)
        let end = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: range.end)
        guard start >= 0, end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func withSuppressedIMEProxyCallbacks<T>(_ body: () -> T) -> T {
        let previous = suppressIMEProxyCallbacks
        suppressIMEProxyCallbacks = true
        defer { suppressIMEProxyCallbacks = previous }
        return body()
    }

    private func resetIMEProxyState() {
        withSuppressedIMEProxyCallbacks {
            imeProxyTextView.text = ""
            imeProxyTextView.selectedRange = NSRange(location: 0, length: 0)
            imeProxyTextView.unmarkText()
        }
    }

    private func syncTextInputModelFromIMEProxy() {
        guard !suppressIMEProxyCallbacks else { return }
        let snapshot = imeProxySnapshot()
        let effects = textInputModel.handleExternalState(
            text: snapshot.text,
            selectedRange: .init(location: snapshot.selectedRange.location, length: snapshot.selectedRange.length),
            markedRange: snapshot.markedRange.map { .init(location: $0.location, length: $0.length) }
        )
        applyTerminalTextInputEffects(effects)
        if snapshot.markedRange == nil {
            syncIMEPreedit(nil)
        }
    }

    private var hasLocalTextInputSession: Bool {
        textInputModel.documentLength > 0 || textInputModel.hasActiveIMEComposition
    }

    private func setIMEProxySelection(_ range: NSRange) {
        withSuppressedIMEProxyCallbacks {
            imeProxyTextView.selectedRange = range
        }
        syncTextInputModelFromIMEProxy()
    }

    private func moveIMEProxyCursorLeft() {
        let selection = imeProxyTextView.selectedRange
        let nsText = (imeProxyTextView.text ?? "") as NSString
        let newLocation: Int
        if selection.length > 0 {
            newLocation = selection.location
        } else if selection.location > 0 {
            let previousRange = nsText.rangeOfComposedCharacterSequence(at: max(selection.location - 1, 0))
            newLocation = previousRange.location
        } else {
            newLocation = 0
        }
        setIMEProxySelection(NSRange(location: newLocation, length: 0))
    }

    private func moveIMEProxyCursorRight() {
        let selection = imeProxyTextView.selectedRange
        let nsText = (imeProxyTextView.text ?? "") as NSString
        let newLocation: Int
        if selection.length > 0 {
            newLocation = selection.location + selection.length
        } else if selection.location < nsText.length {
            let nextRange = nsText.rangeOfComposedCharacterSequence(at: selection.location)
            newLocation = nextRange.location + nextRange.length
        } else {
            newLocation = nsText.length
        }
        setIMEProxySelection(NSRange(location: newLocation, length: 0))
    }

    private func moveIMEProxyCursorToStart() {
        setIMEProxySelection(NSRange(location: 0, length: 0))
    }

    private func moveIMEProxyCursorToEnd() {
        let length = (imeProxyTextView.text ?? "").utf16.count
        setIMEProxySelection(NSRange(location: length, length: 0))
    }

    fileprivate func imeProxyDidDeleteBackward(before: IMEProxySnapshot?) {
        guard !suppressIMEProxyCallbacks else { return }
        let after = imeProxySnapshot()
        if before == after,
           let before,
           before.text.isEmpty,
           before.markedRange == nil,
           before.selectedRange.length == 0,
           before.selectedRange.location == 0 {
            applyTerminalTextInputEffects([.sendSpecialKey(.backspace)])
            return
        }
        syncTextInputModelFromIMEProxy()
    }

    fileprivate func imeProxyFocusDidChange(isFocused: Bool) {
        if let surface = surface?.unsafeCValue {
            ghostty_surface_set_focus(surface, isFocused)
        }
        if isFocused {
            shouldRestoreKeyboardFocusOnReconnect = true
            updateHardwareKeyboardState(reloadInputViewsIfNeeded: true)
        } else {
            stopKeyRepeat()
        }
    }

    fileprivate func imeProxyCaretRect(for position: UITextPosition) -> CGRect {
        let index = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: position)
        return textInputCaretRect(for: index)
    }

    fileprivate func imeProxyFirstRect(for range: UITextRange) -> CGRect {
        let index = imeProxyTextView.offset(from: imeProxyTextView.beginningOfDocument, to: range.start)
        return textInputCaretRect(for: index)
    }

    private func invalidateLocalTextInputSession() {
        resetIMEProxyState()
        let effects = textInputModel.invalidateSession()
        applyTerminalTextInputEffects(effects)
        syncIMEPreedit(nil)
    }

    private func applyTerminalTextInputEffects(_ effects: [TerminalTextInputModel.Effect]) {
        for effect in effects {
            switch effect {
            case .willTextChange, .willSelectionChange, .didTextChange, .didSelectionChange:
                continue
            case let .syncPreedit(text):
                syncIMEPreedit(text)
            case let .sendText(text):
                sendTerminalInputText(text)
            case let .sendBackspaces(count):
                for _ in 0..<count {
                    sendKeyPress(.backspace)
                }
            case let .moveCursor(delta):
                let key: Ghostty.Input.Key = delta < 0 ? .arrowLeft : .arrowRight
                for _ in 0..<abs(delta) {
                    sendKeyPress(key)
                }
            case let .sendSpecialKey(key):
                switch key {
                case .enter:
                    sendKeyPress(.enter)
                case .tab:
                    sendKeyPress(.tab)
                case .backspace:
                    sendKeyPress(.backspace)
                }
            }
        }
    }

    private func textInputCaretRect(for index: Int) -> CGRect {
        guard let surface = surface?.unsafeCValue else {
            let metrics = textInputGridMetrics()
            return CGRect(x: 0, y: 0, width: metrics.cellSize.width, height: metrics.cellSize.height)
        }

        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let cellWidth = max(cellSize.width, CGFloat(max(width, 1)))
        let cellHeight = max(cellSize.height, CGFloat(max(height, 1)))
        let currentCharacterIndex = textInputModel.committedCursorCharacterIndex
        let targetCharacterIndex = textInputModel.committedCharacterIndex(forDocumentOffset: clampTextInputIndex(index))
        let delta = targetCharacterIndex - currentCharacterIndex

        return CGRect(
            x: CGFloat(x) + CGFloat(delta) * cellWidth,
            y: CGFloat(y),
            width: max(CGFloat(width), cellWidth),
            height: max(CGFloat(height), cellHeight)
        )
    }

    // MARK: - UIView Overrides

    override var canBecomeFirstResponder: Bool {
        return true
    }

    private var isTextInputSessionEligible: Bool {
        guard !isShuttingDown else { return false }
        guard window != nil, !isHidden, alpha > 0.01 else { return false }
        if let activationState = window?.windowScene?.activationState {
            return activationState == .foregroundActive
        }
        return UIApplication.shared.applicationState == .active
    }

    var acceptsTerminalInput = true
    private(set) var shouldRestoreKeyboardFocusOnReconnect = false

    func markKeyboardFocusForReconnect() {
        shouldRestoreKeyboardFocusOnReconnect = true
    }

    func clearKeyboardFocusForReconnect() {
        shouldRestoreKeyboardFocusOnReconnect = false
    }

    override var textInputContextIdentifier: String? {
        currentTextInputContextIdentifier
    }

    override var isFirstResponder: Bool {
        super.isFirstResponder || imeProxyTextView.isFirstResponder
    }

    override func becomeFirstResponder() -> Bool {
        guard isTextInputSessionEligible else { return false }
        return imeProxyTextView.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        guard imeProxyTextView.isFirstResponder || super.isFirstResponder else { return true }
        let proxyResult = imeProxyTextView.isFirstResponder ? imeProxyTextView.resignFirstResponder() : true
        let ownResult = super.isFirstResponder ? super.resignFirstResponder() : true
        if (proxyResult && ownResult) || !isTextInputSessionEligible {
            if let surface = surface?.unsafeCValue {
                ghostty_surface_set_focus(surface, false)
            }
            stopKeyRepeat()
        }
        return (proxyResult && ownResult) || !isTextInputSessionEligible
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imeProxyTextView.frame = Self.imeProxyOffscreenFrame

        guard !isShuttingDown else { return }

        // Tell Ghostty the new size after the view has laid out.
        sizeDidChange(bounds.size)

    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        let isVisible = (window != nil)
        isPaused = !isVisible
        if let surface = surface?.unsafeCValue {
            ghostty_surface_set_occlusion(surface, isVisible)
        }

        if isVisible {
            updateHardwareKeyboardState(reloadInputViewsIfNeeded: true)
            sizeDidChange(frame.size)
            // Note: becomeFirstResponder is now handled by SSHTerminalWrapper.updateUIView
            // based on isActive flag to avoid keyboard showing when terminal is hidden
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
                self?.updateHardwareKeyboardState(reloadInputViewsIfNeeded: true)
            }
        )
        hardwareKeyboardObservers.append(
            center.addObserver(
                forName: NSNotification.Name.GCKeyboardDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateHardwareKeyboardState(reloadInputViewsIfNeeded: true)
            }
        )
        updateHardwareKeyboardState(reloadInputViewsIfNeeded: false)
    }

    private func removeHardwareKeyboardObservers() {
        for observer in hardwareKeyboardObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        hardwareKeyboardObservers.removeAll()
    }

    private func updateHardwareKeyboardState(reloadInputViewsIfNeeded: Bool) {
        let hasHardwareKeyboard = traitCollection.userInterfaceIdiom == .pad && GCKeyboard.coalesced != nil
        guard hasHardwareKeyboard != hasHardwareKeyboardAttached else { return }
        hasHardwareKeyboardAttached = hasHardwareKeyboard
        if reloadInputViewsIfNeeded, imeProxyTextView.isFirstResponder, isTextInputSessionEligible {
            imeProxyTextView.reloadInputViews()
        }
    }

    private func markHardwareKeyboardDetectedFromKeyPress() {
        guard traitCollection.userInterfaceIdiom == .pad else { return }
        guard !hasHardwareKeyboardAttached else { return }
        hasHardwareKeyboardAttached = true
        if imeProxyTextView.isFirstResponder, isTextInputSessionEligible {
            imeProxyTextView.reloadInputViews()
        }
    }

    // MARK: - Touch Input

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        // Tap just focuses keyboard - no mouse events (avoids accidental selection)
        _ = becomeFirstResponder()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        // Pan gesture handles scrolling, long press handles selection
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
    }

    private func ghosttyPoint(_ location: CGPoint) -> CGPoint {
        // UIKit coordinates are top-left origin; Ghostty iOS expects the same.
        location
    }

    // MARK: - Scroll Gesture

    /// Scroll speed multiplier for iOS touch scrolling
    private static let scrollMultiplier: Double = 1.5

    /// Momentum deceleration rate (0.0-1.0, higher = slower deceleration)
    private static let momentumDeceleration: Double = 0.92

    /// Minimum velocity to trigger momentum scrolling
    private static let minimumMomentumVelocity: Double = 50.0

    /// Display link for momentum animation
    private var momentumDisplayLink: CADisplayLink?
    private var momentumVelocity: CGPoint = .zero
    private var momentumPhase: Ghostty.Input.Momentum = .none

    @objc private func handlePanGesture(_ recognizer: UIPanGestureRecognizer) {
        guard let surface = surface else { return }
        if isSelecting { return }

        let translation = recognizer.translation(in: self)
        let location = recognizer.location(in: self)

        switch recognizer.state {
        case .began:
            isScrolling = true
            stopMomentumScrolling()
        case .changed:
            // Update mouse position so TUI apps receive wheel events with coordinates.
            let pos = ghosttyPoint(location)
            surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
            // Send scroll delta directly with increased multiplier for snappy feel
            let scrollEvent = Ghostty.Input.MouseScrollEvent(
                x: Double(translation.x) * Self.scrollMultiplier,
                y: Double(translation.y) * Self.scrollMultiplier,
                mods: Ghostty.Input.ScrollMods(precision: true, momentum: .none)
            )
            surface.sendMouseScroll(scrollEvent)
            requestRender()

            // Reset translation so we get delta on next call
            recognizer.setTranslation(.zero, in: self)
        case .ended:
            isScrolling = false
            // Get velocity for momentum scrolling
            let velocity = recognizer.velocity(in: self)
            startMomentumScrolling(velocity: velocity)
        case .cancelled, .failed:
            isScrolling = false
            stopMomentumScrolling()
        default:
            break
        }
    }

    private func startMomentumScrolling(velocity: CGPoint) {
        // Only start momentum if velocity is significant
        guard abs(velocity.y) > Self.minimumMomentumVelocity || abs(velocity.x) > Self.minimumMomentumVelocity else {
            sendMomentumEnd()
            return
        }

        // Scale velocity for momentum (divide by 60 for per-frame amount at 60fps)
        momentumVelocity = CGPoint(
            x: velocity.x / 60.0 * Self.scrollMultiplier * 0.5,
            y: velocity.y / 60.0 * Self.scrollMultiplier * 0.5
        )

        // Create display link for smooth animation
        momentumPhase = .began
        momentumDisplayLink = CADisplayLink(target: self, selector: #selector(momentumScrollTick))
        momentumDisplayLink?.add(to: .main, forMode: .common)
    }

    @objc private func momentumScrollTick() {
        guard let surface = surface else {
            stopMomentumScrolling()
            return
        }

        // Apply deceleration
        momentumVelocity.x *= Self.momentumDeceleration
        momentumVelocity.y *= Self.momentumDeceleration

        // Stop if velocity is very low
        if abs(momentumVelocity.x) < 0.5 && abs(momentumVelocity.y) < 0.5 {
            stopMomentumScrolling()
            sendMomentumEnd()
            return
        }

        // Send momentum scroll event (began -> changed)
        let scrollEvent = Ghostty.Input.MouseScrollEvent(
            x: Double(momentumVelocity.x),
            y: Double(momentumVelocity.y),
            mods: Ghostty.Input.ScrollMods(
                precision: true,
                momentum: momentumPhase == .began ? .began : .changed
            )
        )
        surface.sendMouseScroll(scrollEvent)
        momentumPhase = .changed
        requestRender()
    }

    private func stopMomentumScrolling() {
        momentumDisplayLink?.invalidate()
        momentumDisplayLink = nil
        momentumVelocity = .zero
        momentumPhase = .none
    }

    private func sendMomentumEnd() {
        guard let surface = surface else { return }
        let endEvent = Ghostty.Input.MouseScrollEvent(
            x: 0,
            y: 0,
            mods: Ghostty.Input.ScrollMods(precision: true, momentum: .ended)
        )
        surface.sendMouseScroll(endEvent)
        momentumPhase = .none
    }

    // MARK: - Selection Gestures

    /// Double-tap to select word
    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let surface = surface else { return }
        let location = recognizer.location(in: self)
        let pos = ghosttyPoint(location)

        _ = becomeFirstResponder()

        // Double-click to select word (no modifiers)
        surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
        surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
        surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
        surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
        surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
        requestRender()

        // Show edit menu after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.showEditMenu(at: location)
        }
    }

    /// Triple-tap to select line
    @objc private func handleTripleTap(_ recognizer: UITapGestureRecognizer) {
        guard let surface = surface else { return }
        let location = recognizer.location(in: self)
        let pos = ghosttyPoint(location)

        _ = becomeFirstResponder()

        // Triple-click to select line
        surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
        for _ in 0..<3 {
            surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
            surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
        }
        requestRender()

        // Show edit menu after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.showEditMenu(at: location)
        }
    }

    /// Long press + drag for custom selection
    @objc private func handleSelectionPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let surface = surface else { return }
        let location = recognizer.location(in: self)
        let pos = ghosttyPoint(location)

        switch recognizer.state {
        case .began:
            isSelecting = true
            _ = becomeFirstResponder()
            // Start selection with click (no shift for initial position)
            surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
            surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
            requestRender()
        case .changed:
            // Drag to extend selection
            surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
            requestRender()
        case .ended, .cancelled, .failed:
            surface.sendMousePos(.init(x: pos.x, y: pos.y, mods: []))
            surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
            isSelecting = false
            requestRender()
            showEditMenu(at: location)
        default:
            break
        }
    }

    private func showEditMenu(at location: CGPoint) {
        guard surface?.unsafeCValue != nil else { return }
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: location)
        editMenuInteraction?.presentEditMenu(with: config)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)):
            guard let cSurface = surface?.unsafeCValue else { return false }
            return ghostty_surface_has_selection(cSurface)
        case #selector(paste(_:)):
            return true
        default:
            return false
        }
    }

    @objc override func copy(_ sender: Any?) {
        _ = surface?.perform(action: "copy_to_clipboard")
    }

    @objc override func paste(_ sender: Any?) {
        performPasteAction()
    }

    // MARK: - Software Keyboard (UIKeyInput)

    // MARK: - Keyboard Input (Hardware Keyboard)

    override var keyCommands: [UIKeyCommand]? {
        // Keep keyCommands nil; handle command shortcuts in pressesBegan.
        return nil
    }

    private func handlePasteShortcut(_ key: UIKey) -> Bool {
        let input = key.charactersIgnoringModifiers.lowercased()
        guard input == "v" else { return false }

        if key.modifierFlags.contains(.command) {
            performPasteAction(requestRenderAfterward: true)
            return true
        }

        if key.modifierFlags.contains(.control), interceptRichPasteIfNeeded() {
            return true
        }

        return false
    }

    @discardableResult
    private func interceptRichPasteIfNeeded() -> Bool {
        richPasteInterceptor?(self) == true
    }

    private func performPasteAction(requestRenderAfterward: Bool = false) {
        if interceptRichPasteIfNeeded() {
            if requestRenderAfterward {
                requestRender()
            }
            return
        }

        pasteTextFromClipboard()
        if requestRenderAfterward {
            requestRender()
        }
    }

    private func handleCommandShortcut(_ key: UIKey) -> Bool {
        guard key.modifierFlags.contains(.command) else { return false }
        let input = key.charactersIgnoringModifiers.lowercased()
        switch input {
        case "c":
            if canPerformAction(#selector(copy(_:)), withSender: nil) {
                copy(nil)
            }
            return true
        default:
            return false
        }
    }

    private func shouldRepeatHardwareKey(_ key: UIKey) -> Bool {
        switch key.keyCode {
        case .keyboardDeleteOrBackspace,
             .keyboardDeleteForward,
             .keyboardUpArrow,
             .keyboardDownArrow,
             .keyboardLeftArrow,
             .keyboardRightArrow,
             .keyboardHome,
             .keyboardEnd,
             .keyboardPageUp,
             .keyboardPageDown:
            return true
        default:
            return false
        }
    }

    private func fallbackHardwareKey(for key: UIKey) -> Ghostty.Input.Key? {
        switch key.keyCode {
        case .keyboardLeftShift:
            return .shiftLeft
        case .keyboardRightShift:
            return .shiftRight
        case .keyboardCapsLock:
            return .capsLock
        case .keyboardReturnOrEnter:
            return .enter
        case .keyboardDeleteOrBackspace:
            return .backspace
        case .keyboardDeleteForward:
            return .delete
        case .keyboardTab:
            return .tab
        case .keyboardEscape:
            return .escape
        case .keyboardUpArrow:
            return .arrowUp
        case .keyboardDownArrow:
            return .arrowDown
        case .keyboardLeftArrow:
            return .arrowLeft
        case .keyboardRightArrow:
            return .arrowRight
        case .keyboardHome:
            return .home
        case .keyboardEnd:
            return .end
        case .keyboardPageUp:
            return .pageUp
        case .keyboardPageDown:
            return .pageDown
        default:
            break
        }

        let candidates = [key.charactersIgnoringModifiers, key.characters]
        for candidate in candidates where !candidate.isEmpty {
            switch candidate {
            case "UIKeyInputEscape":
                return .escape
            case "UIKeyInputUpArrow":
                return .arrowUp
            case "UIKeyInputDownArrow":
                return .arrowDown
            case "UIKeyInputLeftArrow":
                return .arrowLeft
            case "UIKeyInputRightArrow":
                return .arrowRight
            case "UIKeyInputHome":
                return .home
            case "UIKeyInputEnd":
                return .end
            case "UIKeyInputPageUp":
                return .pageUp
            case "UIKeyInputPageDown":
                return .pageDown
            case UIKeyCommand.inputEscape:
                return .escape
            case UIKeyCommand.inputUpArrow:
                return .arrowUp
            case UIKeyCommand.inputDownArrow:
                return .arrowDown
            case UIKeyCommand.inputLeftArrow:
                return .arrowLeft
            case UIKeyCommand.inputRightArrow:
                return .arrowRight
            case UIKeyCommand.inputHome:
                return .home
            case UIKeyCommand.inputEnd:
                return .end
            case UIKeyCommand.inputPageUp:
                return .pageUp
            case UIKeyCommand.inputPageDown:
                return .pageDown
            default:
                continue
            }
        }

        return nil
    }

    private func startKeyRepeat(for key: UIKey) {
        guard shouldRepeatHardwareKey(key) else { return }
        let blockedModifiers: UIKeyModifierFlags = [.command, .control, .alternate]
        guard key.modifierFlags.intersection(blockedModifiers).isEmpty else { return }
        stopKeyRepeat()
        repeatingHardwareKey = key
        repeatingFallbackKey = fallbackHardwareKey(for: key)
        repeatingFallbackModifiers = key.modifierFlags
        repeatingKeyCode = UInt16(key.keyCode.rawValue)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.35, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self = self,
                  let cSurface = self.surface?.unsafeCValue else { return }
            if let repeatKey = self.repeatingHardwareKey,
               self.sendDirectHardwareKeyEvent(
                   repeatKey,
                   action: GHOSTTY_ACTION_REPEAT,
                   surface: cSurface
               ) {
                self.requestRender()
                return
            }
            if let fallbackKey = self.repeatingFallbackKey,
               let surface = self.surface {
                surface.sendKeyEvent(
                    self.fallbackHardwareEvent(
                        key: fallbackKey,
                        action: .repeat,
                        modifiers: self.repeatingFallbackModifiers
                    )
                )
            }
            self.requestRender()
        }
        keyRepeatTimer = timer
        timer.resume()
    }

    private func stopKeyRepeat() {
        keyRepeatTimer?.cancel()
        keyRepeatTimer = nil
        repeatingHardwareKey = nil
        repeatingFallbackKey = nil
        repeatingFallbackModifiers = []
        repeatingKeyCode = nil
    }

    private var hasActiveIMEComposition: Bool {
        textInputModel.hasActiveIMEComposition
    }

    private func ghosttyInputAction(_ action: ghostty_input_action_e) -> Ghostty.Input.Action {
        switch action {
        case GHOSTTY_ACTION_PRESS:
            return .press
        case GHOSTTY_ACTION_RELEASE:
            return .release
        case GHOSTTY_ACTION_REPEAT:
            return .repeat
        default:
            return .press
        }
    }

    private func fallbackHardwareEvent(
        key: Ghostty.Input.Key,
        action: Ghostty.Input.Action,
        modifiers: UIKeyModifierFlags
    ) -> Ghostty.Input.KeyEvent {
        let mods = Ghostty.Input.Mods(uiKeyModifiers: modifiers)
        let consumedMods = Ghostty.Input.Mods(
            uiKeyModifiers: modifiers.subtracting([.control, .command])
        )
        return .init(
            key: key,
            action: action,
            text: nil,
            composing: false,
            mods: mods,
            consumedMods: consumedMods,
            unshiftedCodepoint: 0
        )
    }

    private func sendDirectHardwareKeyEvent(
        _ key: UIKey,
        action: ghostty_input_action_e,
        surface cSurface: ghostty_surface_t
    ) -> Bool {
        guard let event = Ghostty.Input.KeyEvent(uiKey: key, action: ghosttyInputAction(action))
        else {
            return false
        }
        return event.withCValue { cEvent in
            ghostty_surface_key(cSurface, cEvent)
        }
    }

    private func shouldRoutePressToSystemTextInput(_ key: UIKey) -> Bool {
        let blockedModifiers: UIKeyModifierFlags = [.command, .control, .alternate]
        guard key.modifierFlags.intersection(blockedModifiers).isEmpty else { return false }
        if hasActiveIMEComposition { return true }
        if fallbackHardwareKey(for: key) != nil { return false }
        // Route only keys that can't be represented directly. Most hardware keys
        // must go through ghostty_surface_key (not insertText) for TUI correctness.
        return key.characters.isEmpty && key.charactersIgnoringModifiers.isEmpty
    }

    fileprivate func processHardwarePressesBegan(_ presses: Set<UIPress>, event _: UIPressesEvent?) -> HardwarePressResult {
        guard let surface = surface, let cSurface = surface.unsafeCValue else {
            return HardwarePressResult(forwardedToSystem: presses, didHandleGhosttyInput: false)
        }

        var result = HardwarePressResult()
        for press in presses {
            guard let key = press.key else {
                result.forwardedToSystem.insert(press)
                continue
            }
            markHardwareKeyboardDetectedFromKeyPress()
            if handlePasteShortcut(key) {
                result.didHandleGhosttyInput = true
                continue
            }
            if handleCommandShortcut(key) { continue }
            if shouldRoutePressToSystemTextInput(key) {
                systemTextInputPresses.insert(UInt16(key.keyCode.rawValue))
                result.forwardedToSystem.insert(press)
                continue
            }

            let keyCode = UInt16(key.keyCode.rawValue)
            if sendDirectHardwareKeyEvent(key, action: GHOSTTY_ACTION_PRESS, surface: cSurface) {
                hardwarePressesSentToGhostty.insert(keyCode)
                fallbackHardwarePressKeys.removeValue(forKey: keyCode)
                fallbackHardwarePressModifiers.removeValue(forKey: keyCode)
                startKeyRepeat(for: key)
                result.didHandleGhosttyInput = true
            } else if let fallbackKey = fallbackHardwareKey(for: key) {
                surface.sendKeyEvent(
                    fallbackHardwareEvent(
                        key: fallbackKey,
                        action: .press,
                        modifiers: key.modifierFlags
                    )
                )
                hardwarePressesSentToGhostty.insert(keyCode)
                fallbackHardwarePressKeys[keyCode] = fallbackKey
                fallbackHardwarePressModifiers[keyCode] = key.modifierFlags
                startKeyRepeat(for: key)
                result.didHandleGhosttyInput = true
            }
        }

        return result
    }

    fileprivate func processHardwarePressesEnded(_ presses: Set<UIPress>, event _: UIPressesEvent?) -> HardwarePressResult {
        guard let surface = surface, let cSurface = surface.unsafeCValue else {
            return HardwarePressResult(forwardedToSystem: presses, didHandleGhosttyInput: false)
        }

        var result = HardwarePressResult()
        for press in presses {
            guard let key = press.key else {
                result.forwardedToSystem.insert(press)
                continue
            }
            let keyCode = UInt16(key.keyCode.rawValue)
            guard hardwarePressesSentToGhostty.contains(keyCode) else {
                fallbackHardwarePressKeys.removeValue(forKey: keyCode)
                fallbackHardwarePressModifiers.removeValue(forKey: keyCode)
                systemTextInputPresses.remove(keyCode)
                result.forwardedToSystem.insert(press)
                continue
            }
            hardwarePressesSentToGhostty.remove(keyCode)
            if repeatingKeyCode == keyCode {
                stopKeyRepeat()
            }
            let fallbackKey = fallbackHardwarePressKeys.removeValue(forKey: keyCode)
            let fallbackModifiers =
                fallbackHardwarePressModifiers.removeValue(forKey: keyCode) ?? key.modifierFlags

            if sendDirectHardwareKeyEvent(key, action: GHOSTTY_ACTION_RELEASE, surface: cSurface) {
                result.didHandleGhosttyInput = true
            } else if let fallbackKey {
                surface.sendKeyEvent(
                    fallbackHardwareEvent(
                        key: fallbackKey,
                        action: .release,
                        modifiers: fallbackModifiers
                    )
                )
                result.didHandleGhosttyInput = true
            }
        }

        return result
    }

    fileprivate func processHardwarePressesCancelled(_ presses: Set<UIPress>) {
        for press in presses {
            guard let key = press.key else { continue }
            let keyCode = UInt16(key.keyCode.rawValue)
            hardwarePressesSentToGhostty.remove(keyCode)
            fallbackHardwarePressKeys.removeValue(forKey: keyCode)
            fallbackHardwarePressModifiers.removeValue(forKey: keyCode)
            systemTextInputPresses.remove(keyCode)
        }
        stopKeyRepeat()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let result = processHardwarePressesBegan(presses, event: event)
        if !result.forwardedToSystem.isEmpty {
            super.pressesBegan(result.forwardedToSystem, with: event)
        }

        if result.didHandleGhosttyInput {
            requestRender()
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let result = processHardwarePressesEnded(presses, event: event)
        if !result.forwardedToSystem.isEmpty {
            super.pressesEnded(result.forwardedToSystem, with: event)
        }

        if result.didHandleGhosttyInput {
            requestRender()
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(presses, with: event)
        processHardwarePressesCancelled(presses)
    }

    // MARK: - Text Input from Software Keyboard

    /// Send text to the terminal (called from keyboard toolbar or software keyboard)
    func sendText(_ text: String) {
        guard acceptsTerminalInput else { return }
        surface?.sendText(text)
        requestRender()
    }

    func pasteTextFromClipboard() {
        guard acceptsTerminalInput else { return }
        _ = surface?.perform(action: "paste_from_clipboard")
        requestRender()
    }

    private func sendTerminalInputText(_ text: String) {
        guard acceptsTerminalInput else { return }

        let normalized = text.precomposedStringWithCanonicalMapping
        guard normalized.count == 1, let character = normalized.first else {
            sendText(normalized)
            return
        }

        guard let mapping = ghosttyKeyMapping(for: character) else {
            sendText(normalized)
            return
        }

        var mods: Ghostty.Input.Mods = []
        if mapping.requiresShift {
            mods.insert(.shift)
        }

        sendModifiedKey(
            mapping.key,
            mods: mods,
            text: mapping.text,
            unshiftedCodepoint: mapping.codepoint,
            invalidateLocalSession: false
        )
    }

    fileprivate func handleIMEProxyInsertText(_ text: String) -> Bool {
        guard acceptsTerminalInput else { return true }

        let normalized = text.precomposedStringWithCanonicalMapping
        if normalized.hasPrefix("UIKeyInput") {
            return true
        }

        let mods = keyboardToolbar?.consumeModifiers() ?? (ctrl: false, alt: false, command: false, shift: false)
        if mods.ctrl, normalized.compare("v", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame,
           interceptRichPasteIfNeeded() {
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

        guard mods.ctrl || mods.alt || mods.command else { return false }
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

    private func sendKeyPress(_ key: Ghostty.Input.Key) {
        guard acceptsTerminalInput else { return }
        guard let surface = surface else { return }
        surface.sendKeyEvent(.init(key: key, action: .press))
        surface.sendKeyEvent(.init(key: key, action: .release))
        requestRender()
    }

    private func sendControlByte(_ value: UInt8) {
        guard acceptsTerminalInput else { return }
        invalidateLocalTextInputSession()
        let scalar = UnicodeScalar(value)
        sendText(String(Character(scalar)))
    }

    private func sendAnsiSequence(_ data: Data) {
        guard acceptsTerminalInput else { return }
        invalidateLocalTextInputSession()
        let text = String(decoding: data, as: UTF8.self)
        sendText(text)
    }

    private func shouldDisplayVisiblePreedit(for text: String) -> Bool {
        TerminalVisiblePreeditPolicy.shouldDisplay(
            text,
            inputModePrimaryLanguage: currentIMEPrimaryLanguage
        )
    }

    private var currentIMEPrimaryLanguage: String? {
        imeProxyTextView.textInputMode?.primaryLanguage ?? textInputMode?.primaryLanguage
    }

    private func syncIMEPreedit(_ text: String?) {
        let visibleText: String?
        if let text, !text.isEmpty {
            let normalized = text.precomposedStringWithCanonicalMapping
            visibleText = shouldDisplayVisiblePreedit(for: normalized) ? normalized : nil
        } else {
            visibleText = nil
        }

        guard visibleText != renderedIMEPreeditText else { return }
        renderedIMEPreeditText = visibleText

        guard let cSurface = surface?.unsafeCValue else { return }

        if let visibleText, !visibleText.isEmpty {
            let len = visibleText.utf8CString.count
            guard len > 0 else {
                ghostty_surface_preedit(cSurface, nil, 0)
                requestRender()
                return
            }
            visibleText.withCString { ptr in
                ghostty_surface_preedit(cSurface, ptr, UInt(len - 1))
            }
        } else {
            ghostty_surface_preedit(cSurface, nil, 0)
        }

        requestRender()
    }

    private func sendModifiedKey(
        _ key: Ghostty.Input.Key,
        mods: Ghostty.Input.Mods,
        text: String? = nil,
        unshiftedCodepoint: UInt32 = 0,
        invalidateLocalSession: Bool = true
    ) {
        guard acceptsTerminalInput else { return }
        guard let surface = surface else { return }
        if invalidateLocalSession {
            invalidateLocalTextInputSession()
        }
        let press = Ghostty.Input.KeyEvent(
            key: key,
            action: .press,
            text: text,
            composing: false,
            mods: mods,
            consumedMods: [],
            unshiftedCodepoint: unshiftedCodepoint
        )
        surface.sendKeyEvent(press)
        let release = Ghostty.Input.KeyEvent(
            key: key,
            action: .release,
            text: nil,
            composing: false,
            mods: mods,
            consumedMods: [],
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

    // MARK: - Process Lifecycle

    /// Check if the terminal process has exited
    var processExited: Bool {
        guard let surface = surface?.unsafeCValue else { return true }
        return ghostty_surface_process_exited(surface)
    }

    /// Check if closing this terminal needs confirmation
    var needsConfirmQuit: Bool {
        guard let surface = surface else { return false }
        return surface.needsConfirmQuit
    }

    /// Get current terminal grid size
    func terminalSize() -> Ghostty.Surface.TerminalSize? {
        guard let surface = surface else { return nil }
        return surface.terminalSize()
    }

    /// Force the terminal surface to refresh/redraw
    func forceRefresh() {
        if isShuttingDown { return }
        if isPaused { return }
        guard let surface = surface?.unsafeCValue else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        updateContentScaleIfNeeded()
        configureIOSurfaceLayers(size: bounds.size)

        // Set scale and size
        let scale = self.contentScaleFactor
        let pixelWidth = floor(bounds.width * scale)
        let pixelHeight = floor(bounds.height * scale)
        guard pixelWidth > 0 && pixelHeight > 0 else { return }
        lastPixelSize = CGSize(width: pixelWidth, height: pixelHeight)
        lastContentScale = scale
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(pixelWidth), UInt32(pixelHeight))
        if window != nil {
            ghostty_surface_set_occlusion(surface, true)
        }

        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
        markIOSurfaceLayersForDisplay()
        requestRender()
    }

    private func configureIOSurfaceLayers() {
        configureIOSurfaceLayers(size: nil)
    }

    private func configureIOSurfaceLayers(size: CGSize?) {
        let scale = self.contentScaleFactor
        guard let sublayers = layer.sublayers else { return }
        let targetBounds = size.map { CGRect(origin: .zero, size: $0) } ?? bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in sublayers {
            sublayer.frame = targetBounds
            sublayer.contentsScale = scale
        }
        CATransaction.commit()
    }

    private func markIOSurfaceLayersForDisplay() {
        layer.setNeedsDisplay()
        layer.sublayers?.forEach { $0.setNeedsDisplay() }
    }

    private func updateContentScaleIfNeeded() {
        let targetScale = window?.screen.scale ?? UIScreen.main.scale
        if contentScaleFactor != targetScale {
            contentScaleFactor = targetScale
        }
    }

    // MARK: - Custom I/O API (for SSH clients)

    /// Callback invoked when user types in the terminal
    var writeCallback: ((Data) -> Void)?

    /// Feed data from SSH channel to the terminal for rendering.
    func feedData(_ data: Data) {
        guard let surface = surface?.unsafeCValue else { return }

        // Feed data to terminal
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ghostty_surface_feed_data(surface, ptr, buffer.count)
        }

        scheduleCustomIORedraw()
        requestRender()
    }

    /// Setup the write callback to capture keyboard input
    func setupWriteCallback() {
        guard let surface = surface?.unsafeCValue else { return }

        let userdata = Unmanaged.passUnretained(self).toOpaque()
        ghostty_surface_set_write_callback(surface, { userdata, data, len in
            guard let userdata = userdata else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
            guard let data = data, len > 0 else { return }
            let swiftData = Data(bytes: data, count: len)
            // Call directly - Ghostty calls this from main thread, no queue hop needed
            view.writeCallback?(swiftData)
        }, userdata)
    }

}

// MARK: - Gesture Recognizer Delegate

extension GhosttyTerminalView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Allow pan and long press to recognize simultaneously
        // The handlers check isSelecting/isScrolling to avoid conflicts
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Long press should win over pan when held long enough
        if gestureRecognizer == scrollRecognizer && otherGestureRecognizer == selectionRecognizer {
            // Only require failure if long press is about to recognize
            return otherGestureRecognizer.state == .began
        }
        return false
    }
}

// MARK: - Edit Menu Interaction Delegate

extension GhosttyTerminalView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        var actions: [UIMenuElement] = []

        if let cSurface = surface?.unsafeCValue, ghostty_surface_has_selection(cSurface) {
            actions.append(UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copy(nil)
            })
        }

        actions.append(UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            self?.paste(nil)
        })

        return UIMenu(children: actions)
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
    private static var keyboardToolbarKey: UInt8 = 0

    private var keyboardToolbar: TerminalInputAccessoryView? {
        get { objc_getAssociatedObject(self, &Self.keyboardToolbarKey) as? TerminalInputAccessoryView }
        set { objc_setAssociatedObject(self, &Self.keyboardToolbarKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var shouldHideKeyboardAccessoryBar: Bool {
        traitCollection.userInterfaceIdiom == .pad && hasHardwareKeyboardAttached
    }

    fileprivate func resolvedInputAccessoryView() -> UIView? {
        guard !shouldHideKeyboardAccessoryBar else {
            return nil
        }
        if keyboardToolbar == nil {
            let toolbar = TerminalInputAccessoryView(onKey: { [weak self] key in
                self?.handleToolbarKey(key)
            }, onCustomAction: { [weak self] action in
                self?.handleToolbarCustomAction(action)
            }, onVoice: onVoiceButtonTapped, onDismissKeyboard: { [weak self] in
                self?.clearKeyboardFocusForReconnect()
                _ = self?.resignFirstResponder()
            })
            keyboardToolbar = toolbar
        } else {
            keyboardToolbar?.onVoice = onVoiceButtonTapped
        }
        return keyboardToolbar
    }

    override var inputAccessoryView: UIView? {
        resolvedInputAccessoryView()
    }

    private func handleToolbarKey(_ key: TerminalKey) {
        sendToolbarKey(key)
    }

    private func sendToolbarKey(_ key: TerminalKey, accumulatedMods: Ghostty.Input.Mods = []) {
        switch key {
        case .modified(let baseKey, let mods):
            sendToolbarKey(baseKey, accumulatedMods: accumulatedMods.union(mods))
        case .escape:
            if accumulatedMods.isEmpty, hasLocalTextInputSession {
                invalidateLocalTextInputSession()
                sendToolbarGhosttyKey(.escape, mods: accumulatedMods, invalidateLocalSession: false)
            } else {
                sendToolbarGhosttyKey(.escape, mods: accumulatedMods, invalidateLocalSession: false)
            }
        case .tab:
            sendToolbarGhosttyKey(.tab, mods: accumulatedMods)
        case .enter:
            sendToolbarGhosttyKey(.enter, mods: accumulatedMods)
        case .backspace:
            if accumulatedMods.isEmpty, hasLocalTextInputSession {
                imeProxyTextView.deleteBackward()
            } else {
                sendToolbarGhosttyKey(.backspace, mods: accumulatedMods)
            }
        case .delete:
            sendToolbarGhosttyKey(.delete, mods: accumulatedMods)
        case .insert:
            sendToolbarGhosttyKey(.insert, mods: accumulatedMods)
        case .arrowUp:
            sendToolbarGhosttyKey(.arrowUp, mods: accumulatedMods)
        case .arrowDown:
            sendToolbarGhosttyKey(.arrowDown, mods: accumulatedMods)
        case .arrowLeft:
            if accumulatedMods.isEmpty, hasLocalTextInputSession {
                moveIMEProxyCursorLeft()
            } else {
                sendToolbarGhosttyKey(.arrowLeft, mods: accumulatedMods)
            }
        case .arrowRight:
            if accumulatedMods.isEmpty, hasLocalTextInputSession {
                moveIMEProxyCursorRight()
            } else {
                sendToolbarGhosttyKey(.arrowRight, mods: accumulatedMods)
            }
        case .home:
            if accumulatedMods.isEmpty, hasLocalTextInputSession {
                moveIMEProxyCursorToStart()
            } else {
                sendToolbarGhosttyKey(.home, mods: accumulatedMods)
            }
        case .end:
            if accumulatedMods.isEmpty, hasLocalTextInputSession {
                moveIMEProxyCursorToEnd()
            } else {
                sendToolbarGhosttyKey(.end, mods: accumulatedMods)
            }
        case .pageUp:
            sendToolbarGhosttyKey(.pageUp, mods: accumulatedMods)
        case .pageDown:
            sendToolbarGhosttyKey(.pageDown, mods: accumulatedMods)
        case .f1:
            sendToolbarGhosttyKey(.f1, mods: accumulatedMods)
        case .f2:
            sendToolbarGhosttyKey(.f2, mods: accumulatedMods)
        case .f3:
            sendToolbarGhosttyKey(.f3, mods: accumulatedMods)
        case .f4:
            sendToolbarGhosttyKey(.f4, mods: accumulatedMods)
        case .f5:
            sendToolbarGhosttyKey(.f5, mods: accumulatedMods)
        case .f6:
            sendToolbarGhosttyKey(.f6, mods: accumulatedMods)
        case .f7:
            sendToolbarGhosttyKey(.f7, mods: accumulatedMods)
        case .f8:
            sendToolbarGhosttyKey(.f8, mods: accumulatedMods)
        case .f9:
            sendToolbarGhosttyKey(.f9, mods: accumulatedMods)
        case .f10:
            sendToolbarGhosttyKey(.f10, mods: accumulatedMods)
        case .f11:
            sendToolbarGhosttyKey(.f11, mods: accumulatedMods)
        case .f12:
            sendToolbarGhosttyKey(.f12, mods: accumulatedMods)
        case .ctrlC:
            sendToolbarControlShortcut(.c, letter: "c", mods: accumulatedMods)
        case .ctrlD:
            sendToolbarControlShortcut(.d, letter: "d", mods: accumulatedMods)
        case .ctrlZ:
            sendToolbarControlShortcut(.z, letter: "z", mods: accumulatedMods)
        case .ctrlL:
            sendToolbarControlShortcut(.l, letter: "l", mods: accumulatedMods)
        case .ctrlA:
            sendToolbarControlShortcut(.a, letter: "a", mods: accumulatedMods)
        case .ctrlE:
            sendToolbarControlShortcut(.e, letter: "e", mods: accumulatedMods)
        case .ctrlK:
            sendToolbarControlShortcut(.k, letter: "k", mods: accumulatedMods)
        case .ctrlU:
            sendToolbarControlShortcut(.u, letter: "u", mods: accumulatedMods)
        }
    }

    private func sendToolbarGhosttyKey(
        _ key: Ghostty.Input.Key,
        mods: Ghostty.Input.Mods,
        text: String? = nil,
        unshiftedCodepoint: UInt32? = nil,
        invalidateLocalSession: Bool = true
    ) {
        let codepoint = unshiftedCodepoint ?? text?.unicodeScalars.first?.value ?? 0
        sendModifiedKey(
            key,
            mods: mods,
            text: text,
            unshiftedCodepoint: codepoint,
            invalidateLocalSession: invalidateLocalSession
        )
    }

    private func sendToolbarControlShortcut(
        _ key: Ghostty.Input.Key,
        letter: String,
        mods: Ghostty.Input.Mods
    ) {
        var mergedMods = mods
        mergedMods.insert(.ctrl)
        let codepoint = letter.unicodeScalars.first?.value ?? 0
        sendToolbarGhosttyKey(key, mods: mergedMods, text: nil, unshiftedCodepoint: codepoint)
    }

    private func handleToolbarCustomAction(_ action: TerminalAccessoryCustomAction) {
        switch action.kind {
        case .command:
            sendText(action.commandContent)
            if action.commandSendMode == .insertAndEnter {
                sendKeyPress(.enter)
            }
        case .shortcut:
            guard let key = Ghostty.Input.Key(rawValue: action.shortcutKey.rawValue) else { return }
            let mods = action.shortcutModifiers.ghosttyModifiers
            let text: String?
            if action.shortcutModifiers.control || action.shortcutModifiers.alternate || action.shortcutModifiers.command {
                text = nil
            } else if action.shortcutModifiers.shift {
                text = action.shortcutKey.shiftedText ?? action.shortcutKey.unshiftedText
            } else {
                text = action.shortcutKey.unshiftedText
            }

            let codepoint = action.shortcutKey.unshiftedText?.unicodeScalars.first?.value ?? 0
            sendToolbarGhosttyKey(key, mods: mods, text: text, unshiftedCodepoint: codepoint)
        }
    }

    private func ghosttyKeyMapping(for character: Character) -> (key: Ghostty.Input.Key, text: String?, codepoint: UInt32, requiresShift: Bool)? {
        let string = String(character)

        for shortcutKey in TerminalAccessoryShortcutKey.allCases {
            if shortcutKey.unshiftedText == string,
               let ghosttyKey = Ghostty.Input.Key(rawValue: shortcutKey.rawValue) {
                let codepoint = shortcutKey.unshiftedText?.unicodeScalars.first?.value ?? 0
                return (ghosttyKey, shortcutKey.unshiftedText, codepoint, false)
            }

            if shortcutKey.shiftedText == string,
               let ghosttyKey = Ghostty.Input.Key(rawValue: shortcutKey.rawValue) {
                let codepoint = shortcutKey.unshiftedText?.unicodeScalars.first?.value ?? 0
                return (ghosttyKey, shortcutKey.shiftedText, codepoint, true)
            }
        }

        return nil
    }
}

private extension TerminalAccessoryShortcutModifiers {
    var ghosttyModifiers: Ghostty.Input.Mods {
        var mods: Ghostty.Input.Mods = []
        if control {
            mods.insert(.ctrl)
        }
        if alternate {
            mods.insert(.alt)
        }
        if command {
            mods.insert(.super)
        }
        if shift {
            mods.insert(.shift)
        }
        return mods
    }
}

// MARK: - Native UIKit Input Accessory View with Glass Effect

private class TerminalInputAccessoryView: UIInputView {
    private let onKey: (TerminalKey) -> Void
    private let onCustomAction: (TerminalAccessoryCustomAction) -> Void
    private let onDismissKeyboard: () -> Void
    var onVoice: (() -> Void)? {
        didSet {
            updateLeadingButtonsState()
        }
    }
    private var ctrlActive = false
    private var altActive = false
    private var commandActive = false
    private var shiftActive = false
    private weak var ctrlButton: UIButton?
    private weak var altButton: UIButton?
    private weak var commandButton: UIButton?
    private weak var shiftButton: UIButton?
    private weak var voiceButton: UIButton?
    private weak var dismissKeyboardButton: UIButton?
    private weak var leadingButtonsStack: UIStackView?
    private weak var leadingButtonsSeparatorView: UIView?
    private weak var backgroundEffectView: UIVisualEffectView?
    private weak var dynamicItemsStack: UIStackView?
    private var scrollLeadingToLeadingButtonsConstraint: NSLayoutConstraint?
    private var scrollLeadingToEdgeConstraint: NSLayoutConstraint?
    private var defaultsObserver: NSObjectProtocol?
    private var accessoryProfileObserver: NSObjectProtocol?
    private var keyRepeatTimer: DispatchSourceTimer?
    private var repeatingKey: TerminalKey?

    init(
        onKey: @escaping (TerminalKey) -> Void,
        onCustomAction: @escaping (TerminalAccessoryCustomAction) -> Void,
        onVoice: (() -> Void)? = nil,
        onDismissKeyboard: @escaping () -> Void
    ) {
        self.onKey = onKey
        self.onCustomAction = onCustomAction
        self.onVoice = onVoice
        self.onDismissKeyboard = onDismissKeyboard
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 48), inputViewStyle: .keyboard)
        setupView()
        observeThemeChanges()
        observeAccessoryProfileChanges()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = accessoryProfileObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        stopKeyRepeat()
    }

    private func setupView() {
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .clear

        let blur = UIVisualEffectView(effect: nil)
        blur.translatesAutoresizingMaskIntoConstraints = false
        insertSubview(blur, at: 0)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        backgroundEffectView = blur
        updateBackgroundEffect()

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)

        let leadingStack = UIStackView()
        leadingStack.translatesAutoresizingMaskIntoConstraints = false
        leadingStack.axis = .horizontal
        leadingStack.spacing = 8
        leadingStack.alignment = .center
        leadingStack.distribution = .fill
        addSubview(leadingStack)
        leadingButtonsStack = leadingStack

        let voice = makeIconButton(icon: "mic.fill") { [weak self] in
            self?.onVoice?()
        }
        voice.accessibilityLabel = String(localized: "Voice input")
        voiceButton = voice
        leadingStack.addArrangedSubview(voice)

        let dismissKeyboard = makeIconButton(icon: "keyboard.chevron.compact.down") { [weak self] in
            self?.onDismissKeyboard()
        }
        dismissKeyboard.accessibilityLabel = String(localized: "Hide keyboard")
        dismissKeyboardButton = dismissKeyboard
        leadingStack.addArrangedSubview(dismissKeyboard)

        let leadingButtonsSeparator = makeSeparator()
        leadingButtonsSeparatorView = leadingButtonsSeparator
        addSubview(leadingButtonsSeparator)

        let leadingToButtons = scrollView.leadingAnchor.constraint(equalTo: leadingButtonsSeparator.trailingAnchor, constant: 10)
        let leadingToEdge = scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        scrollLeadingToLeadingButtonsConstraint = leadingToButtons
        scrollLeadingToEdgeConstraint = leadingToEdge

        NSLayoutConstraint.activate([
            leadingStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leadingStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            leadingButtonsSeparator.leadingAnchor.constraint(equalTo: leadingStack.trailingAnchor, constant: 10),
            leadingButtonsSeparator.centerYAnchor.constraint(equalTo: centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            leadingToButtons,
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.distribution = .fill
        stack.isLayoutMarginsRelativeArrangement = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor, constant: -16)
        ])

        // Modifier buttons (always first, separated)
        let ctrl = makeModifierButton(title: String(localized: "Ctrl")) { [weak self] in
            self?.ctrlActive.toggle()
            self?.updateModifierState()
        }
        let alt = makeModifierButton(title: String(localized: "Alt")) { [weak self] in
            self?.altActive.toggle()
            self?.updateModifierState()
        }
        let shift = makeModifierButton(title: String(localized: "Shift")) { [weak self] in
            self?.shiftActive.toggle()
            self?.updateModifierState()
        }
        ctrlButton = ctrl
        altButton = alt
        shiftButton = shift
        stack.addArrangedSubview(ctrl)
        stack.addArrangedSubview(alt)
        stack.addArrangedSubview(shift)
        stack.addArrangedSubview(makeSeparator())

        let dynamicStack = UIStackView()
        dynamicStack.translatesAutoresizingMaskIntoConstraints = false
        dynamicStack.axis = .horizontal
        dynamicStack.spacing = 8
        dynamicStack.alignment = .center
        // Keep intrinsic widths for text buttons and let UIScrollView handle overflow.
        dynamicStack.setContentHuggingPriority(.required, for: .horizontal)
        dynamicStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.addArrangedSubview(dynamicStack)
        dynamicItemsStack = dynamicStack

        rebuildAccessoryItems()
        updateLeadingButtonsState()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateBackgroundEffect()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateBackgroundEffect()
    }

    private func updateBackgroundEffect() {
        guard let backgroundEffectView else { return }
        let backgroundColor = resolveThemeBackgroundColor()
        updateInterfaceStyle(for: backgroundColor)
        backgroundEffectView.effect = nil
        backgroundEffectView.backgroundColor = backgroundColor
    }

    private func updateInterfaceStyle(for backgroundColor: UIColor) {
        if #available(iOS 13.0, *) {
            let resolved = backgroundColor.resolvedColor(with: traitCollection)
            if let isDark = isDarkBackgroundColor(resolved) {
                overrideUserInterfaceStyle = isDark ? .dark : .light
            } else {
                let style = window?.traitCollection.userInterfaceStyle ?? traitCollection.userInterfaceStyle
                overrideUserInterfaceStyle = style == .unspecified ? .unspecified : style
            }
        }
    }

    private func isDarkBackgroundColor(_ color: UIColor) -> Bool? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
            return luminance < 0.55
        }

        if #available(iOS 13.0, *) {
            let ciColor = CIColor(color: color)
            let luminance = (0.2126 * ciColor.red) + (0.7152 * ciColor.green) + (0.0722 * ciColor.blue)
            return luminance < 0.55
        }

        return nil
    }

    private func observeThemeChanges() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateBackgroundEffect()
            self?.updateLeadingButtonsState()
        }
    }

    private func observeAccessoryProfileChanges() {
        accessoryProfileObserver = NotificationCenter.default.addObserver(
            forName: .terminalAccessoryProfileDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildAccessoryItems()
        }
    }

    private func rebuildAccessoryItems() {
        guard let dynamicItemsStack else { return }

        for arrangedSubview in dynamicItemsStack.arrangedSubviews {
            dynamicItemsStack.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }

        let profile = TerminalAccessoryPreferencesManager.shared.profile
        let customActionsByID = Dictionary(uniqueKeysWithValues: profile.customActions.filter { !$0.isDeleted }.map { ($0.id, $0) })

        for item in profile.layout.activeItems {
            switch item {
            case .system(let actionID):
                guard let button = makeSystemActionButton(for: actionID) else { continue }
                dynamicItemsStack.addArrangedSubview(button)
            case .custom(let actionID):
                guard let action = customActionsByID[actionID] else { continue }
                let button = makeCustomActionButton(for: action)
                dynamicItemsStack.addArrangedSubview(button)
            }
        }
    }

    private func makeSystemActionButton(for actionID: TerminalAccessorySystemActionID) -> UIButton? {
        if actionID == .commandModifier {
            let button = makeModifierButton(title: actionID.toolbarTitle) { [weak self] in
                self?.commandActive.toggle()
                self?.updateModifierState()
            }
            button.accessibilityLabel = actionID.listTitle
            commandButton = button
            updateModifierButton(button, isActive: commandActive)
            return button
        }

        guard let terminalKey = terminalKey(for: actionID) else { return nil }

        let button: UIButton
        if let iconName = actionID.iconName {
            if actionID.isRepeatable {
                button = makeRepeatableIconButton(icon: iconName, key: terminalKey)
            } else {
                button = makeIconButton(icon: iconName) { [weak self] in
                    self?.sendKey(terminalKey)
                }
            }
        } else if actionID.isRepeatable {
            button = makeRepeatablePillButton(title: actionID.toolbarTitle, key: terminalKey)
        } else {
            button = makePillButton(title: actionID.toolbarTitle) { [weak self] in
                self?.sendKey(terminalKey)
            }
        }

        button.accessibilityLabel = actionID.listTitle
        return button
    }

    private func makeCustomActionButton(for action: TerminalAccessoryCustomAction) -> UIButton {
        let visibleTitle = String(action.title.prefix(12))
        let title = visibleTitle.isEmpty ? action.kind.title : visibleTitle
        let button = makePillButton(title: title) { [weak self] in
            self?.sendCustomAction(action)
        }
        button.accessibilityLabel = action.title
        return button
    }

    private func terminalKey(for actionID: TerminalAccessorySystemActionID) -> TerminalKey? {
        switch actionID {
        case .commandModifier: return nil
        case .escape: return .escape
        case .tab: return .tab
        case .shiftTab: return .tab.withShift()
        case .enter: return .enter
        case .backspace: return .backspace
        case .delete: return .delete
        case .insert: return .insert
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .arrowUp: return .arrowUp
        case .arrowDown: return .arrowDown
        case .arrowLeft: return .arrowLeft
        case .arrowRight: return .arrowRight
        case .f1: return .f1
        case .f2: return .f2
        case .f3: return .f3
        case .f4: return .f4
        case .f5: return .f5
        case .f6: return .f6
        case .f7: return .f7
        case .f8: return .f8
        case .f9: return .f9
        case .f10: return .f10
        case .f11: return .f11
        case .f12: return .f12
        case .ctrlC: return .ctrlC
        case .ctrlD: return .ctrlD
        case .ctrlZ: return .ctrlZ
        case .ctrlL: return .ctrlL
        case .ctrlA: return .ctrlA
        case .ctrlE: return .ctrlE
        case .ctrlK: return .ctrlK
        case .ctrlU: return .ctrlU
        case .unknown: return nil
        }
    }

    private func resolveThemeBackgroundColor() -> UIColor {
        let defaults = UserDefaults.standard

        if let cachedHex = defaults.string(forKey: "terminalBackgroundColor") {
            return UIColor(Color.fromHex(cachedHex))
        }

        let usePerAppearance = defaults.object(forKey: "terminalUsePerAppearanceTheme") as? Bool ?? true
        let darkTheme = defaults.string(forKey: "terminalThemeName") ?? "Aizen Dark"
        let lightTheme = defaults.string(forKey: "terminalThemeNameLight") ?? "Aizen Light"
        let themeName: String
        if usePerAppearance {
            themeName = traitCollection.userInterfaceStyle == .dark ? darkTheme : lightTheme
        } else {
            themeName = darkTheme
        }

        if let color = ThemeColorParser.backgroundColor(for: themeName) {
            return UIColor(color)
        }
        return UIColor { traits in
            traits.userInterfaceStyle == .dark ? .black : .systemBackground
        }
    }

    private func makePillButton(title: String, onTap: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .center
        button.clipsToBounds = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
            config.attributedTitle = AttributedString(
                title,
                attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .medium)])
            )
            config.baseForegroundColor = .label
            button.configuration = config
        } else {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            button.setTitleColor(.label, for: .normal)
            button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        }
        button.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.12)
                : UIColor.black.withAlphaComponent(0.06)
        }
        button.layer.cornerRadius = 16
        button.addAction(UIAction { _ in
            onTap()
        }, for: .touchUpInside)

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 32)
        ])

        return button
    }

    private func makeRepeatablePillButton(title: String, key: TerminalKey) -> UIButton {
        let button = RepeatableKeyButton(type: .system)
        button.key = key
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .center
        button.clipsToBounds = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
            config.attributedTitle = AttributedString(
                title,
                attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .medium)])
            )
            config.baseForegroundColor = .label
            button.configuration = config
        } else {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            button.setTitleColor(.label, for: .normal)
            button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        }
        button.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.12)
                : UIColor.black.withAlphaComponent(0.06)
        }
        button.layer.cornerRadius = 16

        button.addTarget(self, action: #selector(repeatButtonDown(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(repeatButtonUp(_:)), for: .touchUpInside)
        button.addTarget(self, action: #selector(repeatButtonUp(_:)), for: .touchUpOutside)
        button.addTarget(self, action: #selector(repeatButtonUp(_:)), for: .touchCancel)
        button.addTarget(self, action: #selector(repeatButtonUp(_:)), for: .touchDragExit)

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 32)
        ])

        return button
    }

    private func makeIconButton(icon: String, onTap: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        button.setImage(UIImage(systemName: icon, withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.12)
                : UIColor.black.withAlphaComponent(0.06)
        }
        button.layer.cornerRadius = 16
        button.addAction(UIAction { _ in
            onTap()
        }, for: .touchUpInside)

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 32)
        ])

        return button
    }

    private func makeRepeatableIconButton(icon: String, key: TerminalKey) -> UIButton {
        let button = RepeatableKeyButton(type: .system)
        button.key = key
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        button.setImage(UIImage(systemName: icon, withConfiguration: config), for: .normal)
        button.tintColor = .label
        button.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.12)
                : UIColor.black.withAlphaComponent(0.06)
        }
        button.layer.cornerRadius = 16

        button.addTarget(self, action: #selector(repeatButtonDown(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(repeatButtonUp(_:)), for: .touchUpInside)
        button.addTarget(self, action: #selector(repeatButtonUp(_:)), for: .touchUpOutside)
        button.addTarget(self, action: #selector(repeatButtonUp(_:)), for: .touchCancel)
        button.addTarget(self, action: #selector(repeatButtonUp(_:)), for: .touchDragExit)

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 32)
        ])

        return button
    }

    private func makeModifierButton(title: String, onTap: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .center
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            config.attributedTitle = AttributedString(
                title,
                attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 13, weight: .semibold)])
            )
            config.baseForegroundColor = .secondaryLabel
            button.configuration = config
        } else {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            button.setTitleColor(.secondaryLabel, for: .normal)
            button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        }
        button.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.08)
                : UIColor.black.withAlphaComponent(0.04)
        }
        button.layer.cornerRadius = 14
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.separator.withAlphaComponent(0.3).cgColor
        button.addAction(UIAction { _ in
            onTap()
        }, for: .touchUpInside)

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 28),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40)
        ])

        return button
    }

    private func makeSeparator() -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .separator.withAlphaComponent(0.4)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 1),
            view.heightAnchor.constraint(equalToConstant: 18)
        ])
        return view
    }

    private func sendKey(_ key: TerminalKey) {
        var modifiedKey = key
        if ctrlActive {
            modifiedKey = modifiedKey.withCtrl()
        }
        if altActive {
            modifiedKey = modifiedKey.withAlt()
        }
        if commandActive {
            modifiedKey = modifiedKey.withCommand()
        }
        if shiftActive {
            modifiedKey = modifiedKey.withShift()
        }
        if ctrlActive || altActive || commandActive || shiftActive {
            ctrlActive = false
            altActive = false
            commandActive = false
            shiftActive = false
            updateModifierState()
        }
        onKey(modifiedKey)
    }

    private func sendCustomAction(_ action: TerminalAccessoryCustomAction) {
        if ctrlActive || altActive || commandActive || shiftActive {
            ctrlActive = false
            altActive = false
            commandActive = false
            shiftActive = false
            updateModifierState()
        }
        onCustomAction(action)
    }

    @objc private func repeatButtonDown(_ sender: RepeatableKeyButton) {
        startKeyRepeat(for: sender.key)
    }

    @objc private func repeatButtonUp(_ sender: RepeatableKeyButton) {
        stopKeyRepeat()
    }

    private func startKeyRepeat(for key: TerminalKey) {
        stopKeyRepeat()
        repeatingKey = key
        sendKey(key)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.35, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self = self, let repeatingKey = self.repeatingKey else { return }
            self.sendKey(repeatingKey)
        }
        keyRepeatTimer = timer
        timer.resume()
    }

    private func stopKeyRepeat() {
        keyRepeatTimer?.cancel()
        keyRepeatTimer = nil
        repeatingKey = nil
    }

    func consumeModifiers() -> (ctrl: Bool, alt: Bool, command: Bool, shift: Bool) {
        let ctrl = ctrlActive
        let alt = altActive
        let command = commandActive
        let shift = shiftActive
        if ctrl || alt || command || shift {
            ctrlActive = false
            altActive = false
            commandActive = false
            shiftActive = false
            updateModifierState()
        }
        return (ctrl, alt, command, shift)
    }

    private func updateModifierState() {
        UIView.animate(withDuration: 0.2) {
            self.updateModifierButton(self.ctrlButton, isActive: self.ctrlActive)
            self.updateModifierButton(self.altButton, isActive: self.altActive)
            self.updateModifierButton(self.commandButton, isActive: self.commandActive)
            self.updateModifierButton(self.shiftButton, isActive: self.shiftActive)
        }
    }

    private func updateModifierButton(_ button: UIButton?, isActive: Bool) {
        guard let button else { return }
        if isActive {
            button.backgroundColor = .systemBlue
            button.layer.borderColor = UIColor.clear.cgColor
            if #available(iOS 15.0, *), var config = button.configuration {
                config.baseForegroundColor = .white
                button.configuration = config
            } else {
                button.setTitleColor(.white, for: .normal)
            }
        } else {
            button.backgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor.white.withAlphaComponent(0.08)
                    : UIColor.black.withAlphaComponent(0.04)
            }
            button.layer.borderColor = UIColor.separator.withAlphaComponent(0.3).cgColor
            if #available(iOS 15.0, *), var config = button.configuration {
                config.baseForegroundColor = .secondaryLabel
                button.configuration = config
            } else {
                button.setTitleColor(.secondaryLabel, for: .normal)
            }
        }
    }

    private func updateLeadingButtonsState() {
        let defaults = UserDefaults.standard
        let voiceEnabled = (defaults.object(forKey: "terminalVoiceButtonEnabled") as? Bool ?? true) && onVoice != nil
        let dismissEnabled = defaults.object(forKey: "terminalKeyboardDismissButtonEnabled") as? Bool ?? true
        let hasVisibleLeadingButton = voiceEnabled || dismissEnabled

        voiceButton?.isHidden = !voiceEnabled
        voiceButton?.isEnabled = voiceEnabled
        voiceButton?.alpha = 1.0

        dismissKeyboardButton?.isHidden = !dismissEnabled
        dismissKeyboardButton?.isEnabled = dismissEnabled
        dismissKeyboardButton?.alpha = 1.0

        leadingButtonsStack?.isHidden = !hasVisibleLeadingButton
        leadingButtonsSeparatorView?.isHidden = !hasVisibleLeadingButton
        scrollLeadingToLeadingButtonsConstraint?.isActive = hasVisibleLeadingButton
        scrollLeadingToEdgeConstraint?.isActive = !hasVisibleLeadingButton
        setNeedsLayout()
    }
}

private final class RepeatableKeyButton: UIButton {
    var key: TerminalKey = .backspace
}

extension GhosttyTerminalView: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        guard textView === imeProxyTextView else { return }
        syncTextInputModelFromIMEProxy()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard textView === imeProxyTextView else { return }
        syncTextInputModelFromIMEProxy()
    }
}

// MARK: - Software Keyboard (UIKeyInput)

extension GhosttyTerminalView: UIKeyInput, UITextInputTraits {
    var hasText: Bool { !(imeProxyTextView.text ?? "").isEmpty }

    func insertText(_ text: String) {
        imeProxyTextView.insertText(text)
    }

    func deleteBackward() {
        imeProxyTextView.deleteBackward()
    }

    var keyboardType: UIKeyboardType {
        get { imeProxyTextView.keyboardType }
        set { imeProxyTextView.keyboardType = newValue }
    }

    var keyboardAppearance: UIKeyboardAppearance {
        get { imeProxyTextView.keyboardAppearance }
        set { imeProxyTextView.keyboardAppearance = newValue }
    }

    var autocorrectionType: UITextAutocorrectionType {
        get { imeProxyTextView.autocorrectionType }
        set { imeProxyTextView.autocorrectionType = newValue }
    }

    var autocapitalizationType: UITextAutocapitalizationType {
        get { imeProxyTextView.autocapitalizationType }
        set { imeProxyTextView.autocapitalizationType = newValue }
    }

    var spellCheckingType: UITextSpellCheckingType {
        get { imeProxyTextView.spellCheckingType }
        set { imeProxyTextView.spellCheckingType = newValue }
    }

    var smartQuotesType: UITextSmartQuotesType {
        get { imeProxyTextView.smartQuotesType }
        set { imeProxyTextView.smartQuotesType = newValue }
    }

    var smartDashesType: UITextSmartDashesType {
        get { imeProxyTextView.smartDashesType }
        set { imeProxyTextView.smartDashesType = newValue }
    }

    var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { imeProxyTextView.smartInsertDeleteType }
        set { imeProxyTextView.smartInsertDeleteType = newValue }
    }

    @available(iOS 17.0, *)
    var inlinePredictionType: UITextInlinePredictionType {
        get { imeProxyTextView.inlinePredictionType }
        set { imeProxyTextView.inlinePredictionType = newValue }
    }

    var enablesReturnKeyAutomatically: Bool {
        get { imeProxyTextView.enablesReturnKeyAutomatically }
        set { imeProxyTextView.enablesReturnKeyAutomatically = newValue }
    }

    var returnKeyType: UIReturnKeyType {
        get { imeProxyTextView.returnKeyType }
        set { imeProxyTextView.returnKeyType = newValue }
    }
}

// MARK: - UITextInput (spacebar cursor control)

extension GhosttyTerminalView: UITextInput {
    var selectedTextRange: UITextRange? {
        get { imeProxyTextView.selectedTextRange }
        set { imeProxyTextView.selectedTextRange = newValue }
    }

    var markedTextRange: UITextRange? {
        imeProxyTextView.markedTextRange
    }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { imeProxyTextView.markedTextStyle }
        set { imeProxyTextView.markedTextStyle = newValue }
    }

    var inputDelegate: UITextInputDelegate? {
        get { imeProxyTextView.inputDelegate }
        set { imeProxyTextView.inputDelegate = newValue }
    }

    var tokenizer: UITextInputTokenizer {
        imeProxyTextView.tokenizer
    }

    var beginningOfDocument: UITextPosition {
        imeProxyTextView.beginningOfDocument
    }

    var endOfDocument: UITextPosition {
        imeProxyTextView.endOfDocument
    }

    func text(in range: UITextRange) -> String? {
        imeProxyTextView.text(in: range)
    }

    func replace(_ range: UITextRange, withText text: String) {
        imeProxyTextView.replace(range, withText: text)
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        imeProxyTextView.setMarkedText(markedText, selectedRange: selectedRange)
    }

    func unmarkText() {
        imeProxyTextView.unmarkText()
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        imeProxyTextView.textRange(from: fromPosition, to: toPosition)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        imeProxyTextView.position(from: position, offset: offset)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        imeProxyTextView.position(from: position, in: direction, offset: offset)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        imeProxyTextView.compare(position, to: other)
    }

    func offset(from: UITextPosition, to other: UITextPosition) -> Int {
        imeProxyTextView.offset(from: from, to: other)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        imeProxyTextView.position(within: range, farthestIn: direction)
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        imeProxyTextView.characterRange(byExtending: position, in: direction)
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        imeProxyTextView.baseWritingDirection(for: position, in: direction)
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
        imeProxyTextView.setBaseWritingDirection(writingDirection, for: range)
    }

    func firstRect(for range: UITextRange) -> CGRect {
        imeProxyTextView.firstRect(for: range)
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        imeProxyTextView.caretRect(for: position)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        imeProxyTextView.selectionRects(for: range)
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        imeProxyTextView.closestPosition(to: point)
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        imeProxyTextView.closestPosition(to: point, within: range)
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        imeProxyTextView.characterRange(at: point)
    }
}

#endif
