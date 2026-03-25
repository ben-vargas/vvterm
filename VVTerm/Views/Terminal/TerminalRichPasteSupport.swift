import Foundation
import Combine
import OSLog
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class TerminalRichPasteUIModel: ObservableObject {
    struct Prompt: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let previewImageData: Data?
        let uploadOnceAction: () -> Void
        let alwaysUploadAction: () -> Void
        let pasteTextAction: (() -> Void)?
        let cancelAction: () -> Void
    }

    struct Banner: Identifiable {
        enum Kind {
            case info
            case success
            case warning
            case error

            var icon: String {
                switch self {
                case .info:
                    return "info.circle.fill"
                case .success:
                    return "checkmark.circle.fill"
                case .warning:
                    return "exclamationmark.triangle.fill"
                case .error:
                    return "xmark.octagon.fill"
                }
            }

            var tint: Color {
                switch self {
                case .info:
                    return .blue
                case .success:
                    return .green
                case .warning:
                    return .orange
                case .error:
                    return .red
                }
            }
        }

        let id = UUID()
        let kind: Kind
        let message: String
    }

    @Published var prompt: Prompt?
    @Published var progressMessage: String?
    @Published var banner: Banner?

    private var bannerDismissTask: Task<Void, Never>?

    func present(prompt: Prompt) {
        self.prompt = prompt
    }

    func dismissPrompt() {
        prompt = nil
    }

    func setProgress(_ message: String?) {
        progressMessage = message
    }

    func showBanner(
        kind: Banner.Kind,
        message: String,
        autoDismissAfter: Duration? = .seconds(4)
    ) {
        bannerDismissTask?.cancel()
        let banner = Banner(kind: kind, message: message)
        self.banner = banner

        guard let autoDismissAfter else { return }
        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(for: autoDismissAfter)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.banner?.id == banner.id else { return }
                self?.banner = nil
            }
        }
    }

    func dismissBanner() {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        banner = nil
    }

    deinit {
        bannerDismissTask?.cancel()
    }
}

extension TerminalRichPasteUIModel {
    var promptBinding: Binding<Prompt?> {
        Binding(
            get: { self.prompt },
            set: { prompt in
                guard prompt == nil, let currentPrompt = self.prompt else { return }
                self.dismissPrompt()
                currentPrompt.cancelAction()
            }
        )
    }
}

struct TerminalTopBannerView: View {
    let icon: String?
    let progressTint: Color?
    let tint: Color
    let message: String
    let dismissAccessibilityLabel: LocalizedStringKey
    let onDismiss: (() -> Void)?

    init(
        icon: String? = nil,
        progressTint: Color? = nil,
        tint: Color,
        message: String,
        dismissAccessibilityLabel: LocalizedStringKey = "Dismiss message",
        onDismiss: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.progressTint = progressTint
        self.tint = tint
        self.message = message
        self.dismissAccessibilityLabel = dismissAccessibilityLabel
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack {
#if os(macOS)
            Spacer()
#endif
            bannerContent
#if os(macOS)
                .frame(maxWidth: 500)
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
#else
                .padding(.horizontal, 12)
                .padding(.top, 8)
#endif
#if !os(macOS)
            Spacer()
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bannerContent: some View {
        HStack(spacing: bannerSpacing) {
            if let progressTint {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(progressTint)
                    .scaleEffect(progressScale)
            }

            if let icon {
                Image(systemName: icon)
                    .font(iconFont)
                    .foregroundStyle(tint)
            }

            Text(message)
                .font(messageFont)
                .foregroundStyle(progressTint == nil ? .secondary : tint)

            Spacer(minLength: 0)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(closeIconFont)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dismissAccessibilityLabel)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(.ultraThinMaterial, in: bannerShape)
        .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
    }

    private var bannerSpacing: CGFloat {
#if os(macOS)
        12
#else
        8
#endif
    }

    private var horizontalPadding: CGFloat {
#if os(macOS)
        16
#else
        12
#endif
    }

    private var verticalPadding: CGFloat {
#if os(macOS)
        12
#else
        8
#endif
    }

    private var cornerRadius: CGFloat {
#if os(macOS)
        999
#else
        10
#endif
    }

    private var progressScale: CGFloat {
#if os(macOS)
        1.05
#else
        1
#endif
    }

    private var shadowColor: Color {
#if os(macOS)
        Color.black.opacity(0.16)
#else
        .clear
#endif
    }

    private var shadowRadius: CGFloat {
#if os(macOS)
        14
#else
        0
#endif
    }

    private var shadowY: CGFloat {
#if os(macOS)
        6
#else
        0
#endif
    }

    @ViewBuilder
    private var bannerShape: some InsettableShape {
#if os(macOS)
        Capsule()
#else
        RoundedRectangle(cornerRadius: cornerRadius)
#endif
    }

    private var iconFont: Font {
#if os(macOS)
        .title3.weight(.semibold)
#else
        .body
#endif
    }

    private var closeIconFont: Font {
#if os(macOS)
        .title3
#else
        .body
#endif
    }

    private var messageFont: Font {
#if os(macOS)
        .body.weight(progressTint == nil ? .medium : .semibold)
#else
        .caption.weight(progressTint == nil ? .regular : .semibold)
#endif
    }
}

struct TerminalRichPasteProgressOverlay: View {
    @ObservedObject var uiModel: TerminalRichPasteUIModel

    var body: some View {
        Group {
            if let progressMessage = uiModel.progressMessage {
                TerminalStatusCard(showsScrim: false) {
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text(progressMessage)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                }
            }
        }
    }
}

struct TerminalRichPasteBannerOverlay: View {
    @ObservedObject var uiModel: TerminalRichPasteUIModel

    var body: some View {
        Group {
            if let banner = uiModel.banner {
                TerminalTopBannerView(
                    icon: banner.kind.icon,
                    tint: banner.kind.tint,
                    message: banner.message,
                    dismissAccessibilityLabel: "Dismiss rich paste message"
                ) {
                    uiModel.dismissBanner()
                }
            }
        }
    }
}

private struct TerminalRichPastePromptModifier: ViewModifier {
    @ObservedObject var uiModel: TerminalRichPasteUIModel

    func body(content: Content) -> some View {
        content.sheet(item: uiModel.promptBinding) { prompt in
            TerminalRichPastePromptSheet(
                prompt: prompt,
                onUploadOnce: {
                    uiModel.dismissPrompt()
                    prompt.uploadOnceAction()
                },
                onAlwaysUpload: {
                    uiModel.dismissPrompt()
                    prompt.alwaysUploadAction()
                },
                onPasteText: prompt.pasteTextAction.map { pasteTextAction in
                    {
                        uiModel.dismissPrompt()
                        pasteTextAction()
                    }
                },
                onCancel: {
                    uiModel.dismissPrompt()
                    prompt.cancelAction()
                }
            )
        }
    }
}

extension View {
    func terminalRichPastePrompt(using uiModel: TerminalRichPasteUIModel) -> some View {
        modifier(TerminalRichPastePromptModifier(uiModel: uiModel))
    }
}

@MainActor
protocol TerminalRichPasteContext: AnyObject {
    var sessionId: UUID { get }
    var uiModel: TerminalRichPasteUIModel { get }

    func resolveConnectedSSHClient() async -> SSHClient?
    func pasteTextFromClipboard()
    func sendText(_ text: String)
}

@MainActor
final class TerminalRichPasteRuntime: TerminalRichPasteContext {
    let sessionId: UUID
    let uiModel: TerminalRichPasteUIModel

    private let resolveConnectedSSHClientHandler: @MainActor () async -> SSHClient?
    private let pasteTextFromClipboardHandler: @MainActor () -> Void
    private let sendTextHandler: @MainActor (String) -> Void
    private lazy var controller = TerminalRichPasteController(
        context: self,
        coordinator: TerminalRichPasteCoordinator(sessionId: sessionId)
    )

    init(
        sessionId: UUID,
        uiModel: TerminalRichPasteUIModel,
        resolveConnectedSSHClient: @escaping @MainActor () async -> SSHClient?,
        pasteTextFromClipboard: @escaping @MainActor () -> Void,
        sendText: @escaping @MainActor (String) -> Void
    ) {
        self.sessionId = sessionId
        self.uiModel = uiModel
        self.resolveConnectedSSHClientHandler = resolveConnectedSSHClient
        self.pasteTextFromClipboardHandler = pasteTextFromClipboard
        self.sendTextHandler = sendText
    }

    static func connectionSession(
        sessionId: UUID,
        sshClient: SSHClient,
        uiModel: TerminalRichPasteUIModel
    ) -> TerminalRichPasteRuntime {
        TerminalRichPasteRuntime(
            sessionId: sessionId,
            uiModel: uiModel,
            resolveConnectedSSHClient: {
                if let registeredClient = ConnectionSessionManager.shared.sshClient(forSessionId: sessionId) {
                    return registeredClient
                }

                if await sshClient.isConnected {
                    return sshClient
                }

                return nil
            },
            pasteTextFromClipboard: {
                ConnectionSessionManager.shared.peekTerminal(for: sessionId)?.pasteTextFromClipboard()
            },
            sendText: { text in
                ConnectionSessionManager.shared.sendText(text, to: sessionId)
            }
        )
    }

    static func terminalPane(
        paneId: UUID,
        sshClient: SSHClient,
        uiModel: TerminalRichPasteUIModel
    ) -> TerminalRichPasteRuntime {
        TerminalRichPasteRuntime(
            sessionId: paneId,
            uiModel: uiModel,
            resolveConnectedSSHClient: {
                if let registeredClient = TerminalTabManager.shared.getSSHClient(for: paneId) {
                    return registeredClient
                }

                if await sshClient.isConnected {
                    return sshClient
                }

                return nil
            },
            pasteTextFromClipboard: {
                TerminalTabManager.shared.getTerminal(for: paneId)?.pasteTextFromClipboard()
            },
            sendText: { text in
                TerminalTabManager.shared.getTerminal(for: paneId)?.sendText(text)
            }
        )
    }

    func install(on terminal: GhosttyTerminalView) {
        terminal.richPasteInterceptor = { [weak self] _ in
            self?.controller.interceptPaste() ?? false
        }
    }

    func resolveConnectedSSHClient() async -> SSHClient? {
        await resolveConnectedSSHClientHandler()
    }

    func pasteTextFromClipboard() {
        pasteTextFromClipboardHandler()
    }

    func sendText(_ text: String) {
        sendTextHandler(text)
    }
}

@MainActor
final class TerminalRichPasteController {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "TerminalRichPaste")
    private unowned let context: any TerminalRichPasteContext
    private let coordinator: TerminalRichPasteCoordinator
    private var activePasteTask: Task<Void, Never>?
    private var activePasteTaskID: UUID?

    init(
        context: any TerminalRichPasteContext,
        coordinator: TerminalRichPasteCoordinator
    ) {
        self.context = context
        self.coordinator = coordinator
    }

    func interceptPaste() -> Bool {
        let settings = RichClipboardSettings()
        guard settings.isImagePasteEnabled else { return false }

        let snapshot = Clipboard.snapshot()
        guard snapshot.hasImage else { return false }
        logger.info(
            "Intercepted rich paste [session: \(self.context.sessionId.uuidString, privacy: .public)] [mode: \(settings.imagePasteBehavior.rawValue, privacy: .public)] [bytes: \(snapshot.image?.sizeBytes ?? 0)]"
        )

        switch settings.imagePasteBehavior {
        case .disabled:
            return false
        case .askOnce:
            Task { @MainActor [weak self] in
                self?.presentPrompt(for: snapshot, settings: settings)
            }
            return true
        case .automatic:
            Task { @MainActor [weak self] in
                self?.startRichPaste(with: snapshot, settings: settings)
            }
            return true
        }
    }

    private func presentPrompt(for snapshot: ClipboardSnapshot, settings: RichClipboardSettings) {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let sizeLabel = formatter.string(fromByteCount: Int64(snapshot.image?.sizeBytes ?? 0))
        let message = String(
            format: String(localized: "Upload this %@ image and paste its path?"),
            sizeLabel
        )

        logger.info(
            "Presenting rich paste prompt [session: \(self.context.sessionId.uuidString, privacy: .public)] [bytes: \(snapshot.image?.sizeBytes ?? 0)]"
        )
        self.context.uiModel.present(
            prompt: .init(
                title: String(localized: "Paste image"),
                message: message,
                previewImageData: snapshot.image?.data,
                uploadOnceAction: { [weak self] in
                    self?.startRichPaste(with: snapshot, settings: settings)
                },
                alwaysUploadAction: { [weak self] in
                    self?.rememberAutomaticImagePaste()
                    self?.startRichPaste(with: snapshot, settings: settings)
                },
                pasteTextAction: snapshot.hasText ? { [weak self] in
                    self?.pasteTextFromClipboard()
                } : nil,
                cancelAction: { }
            )
        )
    }

    private func rememberAutomaticImagePaste() {
        RichClipboardSettings.persistImagePasteBehavior(.automatic)
    }

    private func startRichPaste(with snapshot: ClipboardSnapshot, settings: RichClipboardSettings) {
        guard let image = snapshot.image else { return }
        logger.info(
            "Starting rich paste [session: \(self.context.sessionId.uuidString, privacy: .public)] [bytes: \(image.sizeBytes)]"
        )

        self.context.uiModel.dismissPrompt()
        self.context.uiModel.dismissBanner()
        activePasteTask?.cancel()
        let taskID = UUID()
        activePasteTaskID = taskID
        activePasteTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.activePasteTaskID == taskID {
                    self.activePasteTask = nil
                    self.activePasteTaskID = nil
                }
            }
            await self?.performRichPaste(image: image, settings: settings)
        }
    }

    private func pasteTextFromClipboard() {
        self.context.uiModel.dismissPrompt()
        self.context.uiModel.setProgress(nil)
        self.context.pasteTextFromClipboard()
    }

    private func performRichPaste(image: ClipboardImagePayload, settings: RichClipboardSettings) async {
        logger.info(
            "Uploading clipboard image [session: \(self.context.sessionId.uuidString, privacy: .public)] [bytes: \(image.sizeBytes)] [format: \(image.suggestedExtension, privacy: .public)]"
        )

        guard let activeSSHClient = await self.context.resolveConnectedSSHClient() else {
            logger.warning(
                "Rich paste skipped because no active SSH client is available [session: \(self.context.sessionId.uuidString, privacy: .public)]"
            )
            self.context.uiModel.showBanner(
                kind: .error,
                message: String(localized: "Reconnect the terminal before uploading images."),
                autoDismissAfter: .seconds(6)
            )
            return
        }

        self.context.uiModel.setProgress(String(localized: "Uploading image to remote host..."))
        defer { self.context.uiModel.setProgress(nil) }

        do {
            let result = try await self.coordinator.performRichPaste(
                image: image,
                settings: settings,
                sshClient: activeSSHClient
            )
            self.handleResult(result)
        } catch is CancellationError {
            logger.info("Rich paste cancelled [session: \(self.context.sessionId.uuidString, privacy: .public)]")
            return
        } catch {
            logger.error(
                "Rich paste failed [session: \(self.context.sessionId.uuidString, privacy: .public)] [error: \(error.localizedDescription, privacy: .public)]"
            )
            let bannerMessage: String
            if let sshError = error as? SSHError, case .notConnected = sshError {
                bannerMessage = String(localized: "Reconnect the terminal before uploading images.")
            } else {
                bannerMessage = error.localizedDescription
            }
            self.context.uiModel.showBanner(
                kind: .error,
                message: bannerMessage,
                autoDismissAfter: .seconds(6)
            )
        }
    }

    private func handleResult(_ result: RichPasteUploadResult) {
        logger.info(
            "Rich paste uploaded remote path [session: \(self.context.sessionId.uuidString, privacy: .public)] [path: \(result.remotePath, privacy: .public)] [seeded: \(result.seededRemoteClipboard)]"
        )
        // Paste the remote file as one POSIX shell token so TMPDIR spaces do not break the command line.
        self.context.sendText(RemoteTerminalBootstrap.posixPastedPath(result.remotePath))
    }

    deinit {
        activePasteTask?.cancel()
        activePasteTaskID = nil
    }
}

struct TerminalRichPastePromptSheet: View {
    let prompt: TerminalRichPasteUIModel.Prompt
    let onUploadOnce: () -> Void
    let onAlwaysUpload: () -> Void
    let onPasteText: (() -> Void)?
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(iOS)
        NavigationStack {
            contentBody
                .navigationTitle(prompt.title)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    actionRow
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        closeButton
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .interactiveDismissDisabled()
        }
        #else
        VStack(spacing: 0) {
            DialogSheetHeader(title: LocalizedStringKey(prompt.title)) {
                cancelAndDismiss()
            }

            Divider()

            contentBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            actionRow
        }
        .frame(minWidth: 520, minHeight: 500)
        #endif
    }

    private var closeButton: some View {
        Button {
            cancelAndDismiss()
        } label: {
            #if os(macOS)
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                )
            #else
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            #endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }

    private var contentBody: some View {
        VStack(spacing: 18) {
            previewCard
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            promptCopy
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var actionRow: some View {
        #if os(macOS)
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                actionButton(
                    title: String(localized: "Upload image"),
                    systemImage: "arrow.up.circle",
                    isPrimary: false,
                    action: confirmAndDismiss(onUploadOnce)
                )

                actionButton(
                    title: String(localized: "Always Upload"),
                    systemImage: "bolt.badge.checkmark",
                    isPrimary: true,
                    action: confirmAndDismiss(onAlwaysUpload)
                )
            }

            if let onPasteText {
                actionButton(
                    title: String(localized: "Paste Text Instead"),
                    systemImage: "text.insert",
                    isPrimary: false,
                    action: confirmAndDismiss(onPasteText)
                )
                .frame(maxWidth: 460)
            }
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 20)
        #else
        VStack(spacing: 10) {
            actionButton(
                title: String(localized: "Always Upload"),
                systemImage: "bolt.badge.checkmark",
                isPrimary: true,
                action: confirmAndDismiss(onAlwaysUpload)
            )

            actionButton(
                title: String(localized: "Upload image"),
                systemImage: "arrow.up.circle",
                isPrimary: false,
                action: confirmAndDismiss(onUploadOnce)
            )

            if let onPasteText {
                actionButton(
                    title: String(localized: "Paste Text Instead"),
                    systemImage: "text.insert",
                    isPrimary: false,
                    action: confirmAndDismiss(onPasteText)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        #endif
    }

    private func actionButton(
        title: String,
        systemImage: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .font(isPrimary ? .headline : .callout.weight(.semibold))
                .foregroundStyle(isPrimary ? Color.white : Color.secondary)
                .background {
                    if isPrimary {
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var promptCopy: some View {
        VStack(spacing: 8) {
            Text(prompt.message)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Text(String(localized: "Always Upload skips this prompt next time."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var previewCard: some View {
        if let previewImage {
            previewImage
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .top)
                .frame(minHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: 10)
        } else {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
                .frame(minHeight: 300)
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.arrow.down")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.accent)

                        Text(String(localized: "Image ready to upload"))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
        }
    }

    private var previewImage: Image? {
        guard let data = prompt.previewImageData else { return nil }
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #else
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #endif
    }

    private func confirmAndDismiss(_ action: @escaping () -> Void) -> () -> Void {
        {
            action()
            dismiss()
        }
    }

    private func cancelAndDismiss() {
        onCancel()
        dismiss()
    }
}
