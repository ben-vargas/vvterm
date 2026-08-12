import SwiftUI
import UniformTypeIdentifiers

struct RemoteFileBrowserScreen: View {
    @ObservedObject var browser: RemoteFileBrowserStore
    @ObservedObject var operationCoordinator: RemoteFileOperationCoordinator
    let server: Server
    let fileTab: RemoteFileTab
    let appearance: TerminalAppearanceSnapshot
    let initialPath: String?
    let onCurrentPathChange: @MainActor (String?) -> Void

    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var appLockManager: AppLockManager
    @State var presentedPreviewPath: String?
    @State var presentation: RemoteFileBrowserPresentation?
    @State var pendingDownloadTransferID: UUID?
    @State var isDropTargeted = false
    @StateObject var platformState = RemoteFileBrowserPlatformState()
    @StateObject var noticeHost = NoticeHostModel()

    struct Snapshot {
        let currentPath: String
        let breadcrumbs: [RemoteFileBreadcrumb]
        let entries: [RemoteFileEntry]
        let selectedEntry: RemoteFileEntry?
        let viewerPayload: RemoteFileViewerPayload?
        let directoryError: RemoteFileBrowserError?
        let viewerError: RemoteFileBrowserError?
        let isLoadingDirectory: Bool
        let isLoadingViewer: Bool
        let sort: RemoteFileSort
        let sortDirection: RemoteFileSortDirection
        let showHiddenFiles: Bool
        let isTruncated: Bool
        let selectedPath: String?
        let filesystemStatus: RemoteFileFilesystemStatus?
    }

    struct EmptyStateContent {
        let icon: String
        let title: String
        let message: String
    }

    init(
        browser: RemoteFileBrowserStore,
        server: Server,
        fileTab: RemoteFileTab,
        appearance: TerminalAppearanceSnapshot,
        initialPath: String? = nil,
        onCurrentPathChange: @escaping @MainActor (String?) -> Void = { _ in }
    ) {
        self.browser = browser
        self.server = server
        self.fileTab = fileTab
        self.appearance = appearance
        self.initialPath = initialPath
        self.onCurrentPathChange = onCurrentPathChange
        _operationCoordinator = ObservedObject(
            wrappedValue: browser.operationCoordinator(for: fileTab, server: server)
        )
    }

    var snapshot: Snapshot {
        let entries = browser.entries(for: fileTab)
        let viewerPayload = browser.viewerPayload(for: fileTab)
        let selectedPath = browser.selectedEntryPath(for: fileTab) ?? viewerPayload?.entry.path
        let selectedEntry = entries.first(where: { $0.path == selectedPath }) ?? viewerPayload?.entry

        return Snapshot(
            currentPath: browser.currentPath(for: fileTab),
            breadcrumbs: browser.breadcrumbs(for: fileTab),
            entries: entries,
            selectedEntry: selectedEntry,
            viewerPayload: viewerPayload,
            directoryError: browser.error(for: fileTab),
            viewerError: browser.viewerError(for: fileTab),
            isLoadingDirectory: browser.isLoading(for: fileTab),
            isLoadingViewer: browser.isLoadingViewer(for: fileTab),
            sort: browser.sort(for: fileTab),
            sortDirection: browser.sortDirection(for: fileTab),
            showHiddenFiles: browser.showHiddenFiles(for: fileTab),
            isTruncated: browser.isTruncated(for: fileTab),
            selectedPath: selectedPath,
            filesystemStatus: browser.filesystemStatus(for: fileTab)
        )
    }

    var initialLoadTaskID: String {
        "\(server.id.uuidString):\(fileTab.id.uuidString):\(initialPath ?? "")"
    }

    var remoteRowDropTypeIdentifiers: [String] {
        [UTType.vvtermRemoteFileEntry.identifier, UTType.fileURL.identifier]
    }

    var terminalThemeBackgroundColor: Color {
        Color.fromHex(appearance.activeTheme.palette.backgroundHex)
    }

    @ViewBuilder
    func renameSheet(entry: RemoteFileEntry) -> some View {
        platformRenameSheetSizing(RemoteFileRenameSheet(
            entry: entry,
            proposedName: renameNameBinding,
            isSubmitting: isRenameSubmitting,
            onCancel: resetRenamePrompt,
            onRename: { renameEntry() }
        ))
    }

    func moveSheet(entry: RemoteFileEntry) -> some View {
        let fileBrowser = browser
        let fileServer = server

        return platformMoveSheetSizing(RemoteFileMoveSheet(
            entry: entry,
            destinationDirectory: moveDestinationBinding,
            onLoadDirectories: { path in
                try await fileBrowser.listDirectories(at: path, server: fileServer)
            },
            isSubmitting: isMoveSubmitting,
            onCancel: resetMovePrompt,
            onMove: moveEntry
        ))
    }

    @ViewBuilder
    func deleteSheet(entry: RemoteFileEntry) -> some View {
        RemoteFileDeleteConfirmationSheet(
            entry: entry,
            message: deleteAlertMessage(for: entry),
            onCancel: dismissPresentation,
            onDelete: deleteEntry
        )
    }

    @ViewBuilder
    func permissionSheet(entry: RemoteFileEntry) -> some View {
        platformPermissionSheetSizing(RemoteFilePermissionEditorSheet(
            entry: entry,
            draft: permissionDraftBinding,
            originalAccessBits: permissionOriginalAccessBits,
            preservedBits: permissionPreservedBits,
            errorMessage: permissionErrorMessage,
            isSubmitting: isPermissionSubmitting,
            onCancel: resetPermissionEditor,
            onApply: applyPermissions
        ))
    }

    var body: some View {
        let base = fileNoticeHost {
            ZStack {
                platformContent(snapshot)

                if isDropTargeted {
                    RemoteFileDropOverlay()
                        .padding(20)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .task(id: initialLoadTaskID) {
            await browser.loadInitialPath(for: server, tab: fileTab, initialPath: initialPath)
            presentDirectorySecurityApprovalIfNeeded()
        }
        .onAppear {
            onCurrentPathChange(browser.lastVisitedPath(for: fileTab))
        }

        let withDownloadExport = downloadExportPresentation(base)
        let withSearch = platformSearchPresentation(withDownloadExport)
        let withDrop = platformDropPresentation(withSearch, snapshot: snapshot)
        let withRoutes = platformPresentation(withDrop)
            .alert(item: alertPresentationBinding) { route in
                alert(for: route)
            }

        let withPathTracking = withRoutes
        .onChange(of: snapshot.currentPath) { newValue in
            onCurrentPathChange(newValue)
            if case .createFolder(let draft) = presentation,
               draft.destinationPath != newValue {
                resetNewFolderPrompt()
            }
            platformCurrentPathDidChange()
        }

        let withToolbarCommands = withPathTracking
        .onChange(of: browser.pendingToolbarCommand?.id) { _ in
            handlePendingToolbarCommand()
        }

        let withSecurityObservation = platformSelectionTrackingPresentation(
            withToolbarCommands,
            snapshot: snapshot
        )
            .onChange(of: snapshot.directoryError) { _ in
                presentDirectorySecurityApprovalIfNeeded()
            }
            .onChange(of: snapshot.viewerError) { _ in
                presentViewerSecurityApprovalIfNeeded()
            }

        securityApprovalPresentation(withSecurityObservation)
    }

    @ViewBuilder
    func fileNoticeHost<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NoticeHost(
            topBanner: noticeHost.topBanner,
            bottomOperations: noticeHost.bottomOperations + operationNotices,
            bottomInsetBehavior: .contentBottom
        ) {
            content()
        }
    }

    @ViewBuilder
    func downloadExportPresentation<Content: View>(_ content: Content) -> some View {
        if #available(iOS 17, macOS 14, *) {
            content.fileExporter(
                isPresented: downloadExporterBinding,
                document: downloadExportDocument,
                contentTypes: [.data],
                defaultFilename: downloadExportFilename,
                onCompletion: handleDownloadExportCompletion,
                onCancellation: handleDownloadExportCancellation
            )
        } else {
            content.fileExporter(
                isPresented: downloadExporterBinding,
                document: downloadExportDocument,
                contentType: .data,
                defaultFilename: downloadExportFilename,
                onCompletion: handleDownloadExportCompletion
            )
        }
    }

    var alertPresentationBinding: Binding<RemoteFileBrowserPresentation?> {
        Binding(
            get: {
                guard presentation?.isAlert == true else { return nil }
                return presentation
            },
            set: { route in
                if let route {
                    presentation = route
                } else if presentation?.isAlert == true {
                    dismissPresentation()
                }
            }
        )
    }

    func alert(for route: RemoteFileBrowserPresentation) -> Alert {
        switch route {
        case .operationError(let message):
            Alert(
                title: Text(String(localized: "Files")),
                message: Text(message),
                dismissButton: .cancel(Text(String(localized: "OK")), action: dismissPresentation)
            )
        case .transferCancellation(let request):
            Alert(
                title: Text(request.kind.confirmationTitle),
                message: Text(request.kind.confirmationMessage),
                primaryButton: .cancel(Text(request.kind.keepButtonTitle), action: dismissPresentation),
                secondaryButton: .destructive(Text(request.kind.cancelButtonTitle)) {
                    cancelTransfer(id: request.id)
                }
            )
        default:
            Alert(title: Text(String(localized: "Files")))
        }
    }

    var downloadExporterBinding: Binding<Bool> {
        Binding(
            get: { presentation?.isDownloadExport == true },
            set: { isPresented in
                if !isPresented, presentation?.isDownloadExport == true {
                    handleDownloadExportCancellation()
                }
            }
        )
    }

    var downloadExportDocument: RemoteFileDownloadDocument? {
        guard case .downloadExport(let export) = presentation else { return nil }
        return export.document
    }

    var downloadExportFilename: String {
        guard case .downloadExport(let export) = presentation else { return "" }
        return export.filename
    }

    func deleteAlertMessage(for entry: RemoteFileEntry) -> String {
        let itemName = entry.name.isEmpty ? entry.path : entry.name
        return String(
            format: String(localized: "This will permanently remove \"%@\" from the remote server. This cannot be undone."),
            itemName
        )
    }

    @MainActor
    func copyPathToClipboard(_ path: String) {
        Clipboard.copy(path)
        noticeHost.show(
            NoticeItem(
                id: UUID().uuidString,
                lane: .topBanner,
                level: .success,
                leading: .icon("checkmark.circle.fill"),
                message: String(localized: "Path copied to clipboard."),
                lifetime: .autoDismiss(.seconds(1.5))
            )
        )
    }

    func transferProgress(
        completedUnitCount: Int?,
        totalUnitCount: Int?
    ) -> NoticeProgress? {
        guard let completedUnitCount, let totalUnitCount else { return nil }
        return NoticeProgress(
            completedUnitCount: completedUnitCount,
            totalUnitCount: totalUnitCount
        )
    }

    func transferDetail(fileName: String?, filePath: String?) -> String? {
        if let filePath, !filePath.isEmpty {
            return filePath
        }

        if let fileName, !fileName.isEmpty {
            return fileName
        }

        return nil
    }

    func transferCompletionAction(fileURL: URL?) -> NoticeAction? {
        platformTransferCompletionAction(fileURL: fileURL)
    }

    var operationNotices: [NoticeItem] {
        operationCoordinator.operations.map { operation in
            let message: String
            let level: NoticeLevel
            let leading: NoticeLeading
            let progress: NoticeProgress?
            let dismissAction: (() -> Void)?

            switch operation.phase {
            case .running(let currentMessage, let completed, let total):
                message = currentMessage
                level = .info
                leading = .activity
                progress = transferProgress(
                    completedUnitCount: completed,
                    totalUnitCount: total
                )
                dismissAction = { requestTransferCancellation(id: operation.id) }
            case .awaitingSecurityApproval(let currentMessage):
                message = currentMessage
                level = .warning
                leading = .icon("lock.shield.fill")
                progress = nil
                dismissAction = { requestTransferCancellation(id: operation.id) }
            case .succeeded(let currentMessage):
                message = currentMessage
                level = .success
                leading = .icon("checkmark.circle.fill")
                progress = nil
                dismissAction = { operationCoordinator.dismiss(operation.id) }
            case .failed(let currentMessage):
                message = currentMessage
                level = .error
                leading = .icon("xmark.octagon.fill")
                progress = nil
                dismissAction = { operationCoordinator.dismiss(operation.id) }
            }

            return NoticeItem(
                id: operation.id.uuidString,
                lane: .bottomOperation,
                level: level,
                leading: leading,
                title: operation.title,
                message: message,
                detail: transferDetail(
                    fileName: operation.completion?.fileName,
                    filePath: operation.completion?.filePath
                ),
                progress: progress,
                action: transferCompletionAction(fileURL: operation.completion?.fileURL),
                dismissAction: dismissAction
            )
        }
    }

    @MainActor
    func performTransfer(
        id: UUID = UUID(),
        cancellationKind: RemoteFileTransferKind = .transfer,
        title: String,
        initialMessage: String,
        successMessage: String,
        successFileURL: URL? = nil,
        successFileName: String? = nil,
        successFilePath: String? = nil,
        keepsSuccessVisible: Bool = false,
        onSuccess: (@MainActor () -> Void)? = nil,
        operation: @escaping (@escaping @MainActor @Sendable (RemoteFileBrowserStore.TransferProgress) -> Void) async throws -> Void
    ) {
        operationCoordinator.start(
            id: id,
            kind: cancellationKind == .upload ? .upload : .transfer,
            title: title,
            initialMessage: initialMessage,
            successMessage: successMessage,
            completion: .init(
                fileURL: successFileURL,
                fileName: successFileName,
                filePath: successFilePath
            ),
            keepsSuccessVisible: keepsSuccessVisible,
            onSuccess: onSuccess,
            operation: operation
        )
    }

    @MainActor
    func performTransfer(
        id: UUID = UUID(),
        cancellationKind: RemoteFileTransferKind = .transfer,
        title: String,
        initialMessage: String,
        successMessage: String,
        successFileURL: URL? = nil,
        successFileName: String? = nil,
        successFilePath: String? = nil,
        keepsSuccessVisible: Bool = false,
        onSuccess: (@MainActor () -> Void)? = nil,
        operation: @escaping () async throws -> Void
    ) {
        performTransfer(
            id: id,
            cancellationKind: cancellationKind,
            title: title,
            initialMessage: initialMessage,
            successMessage: successMessage,
            successFileURL: successFileURL,
            successFileName: successFileName,
            successFilePath: successFilePath,
            keepsSuccessVisible: keepsSuccessVisible,
            onSuccess: onSuccess
        ) { _ in
            try await operation()
        }
    }

    @MainActor
    func requestTransferCancellation(id: UUID) {
        guard let operation = operationCoordinator.operations.first(where: { $0.id == id }) else {
            return
        }
        presentation = .transferCancellation(RemoteFileTransferCancellationRequest(
            id: id,
            kind: operation.kind == .upload ? .upload : .transfer
        ))
    }

    @MainActor
    func cancelTransfer(id: UUID) {
        operationCoordinator.cancel(id)
        dismissPresentation()
    }

    func performOperation(
        onFailure: (@MainActor (Error) -> Void)? = nil,
        operation: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        operationCoordinator.run(
            operation: operation,
            onSuccess: { _ in },
            onFailure: { error in
                if let onFailure { onFailure(error) } else { presentOperationError(error) }
            }
        )
    }

    func performOperation<Result>(
        operation: @escaping @MainActor @Sendable () async throws -> Result,
        onSuccess: @escaping @MainActor (Result) -> Void,
        onFailure: (@MainActor (Error) -> Void)? = nil,
    ) {
        operationCoordinator.run(
            operation: operation,
            onSuccess: onSuccess,
            onFailure: { error in
                if let onFailure { onFailure(error) } else { presentOperationError(error) }
            }
        )
    }

    var trimmedNewFolderName: String {
        guard case .createFolder(let draft) = presentation else { return "" }
        return draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedRenameName: String {
        guard case .rename(let draft) = presentation else { return "" }
        return draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isCreateFolderSubmitting: Bool {
        guard case .createFolder(let draft) = presentation else { return false }
        return draft.isSubmitting
    }

    var isRenameSubmitting: Bool {
        guard case .rename(let draft) = presentation else { return false }
        return draft.isSubmitting
    }

    var isMoveSubmitting: Bool {
        guard case .move(let draft) = presentation else { return false }
        return draft.isSubmitting
    }

    var isPermissionSubmitting: Bool {
        guard case .permissions(let draft) = presentation else { return false }
        return draft.isSubmitting
    }

    var permissionOriginalAccessBits: UInt32 {
        guard case .permissions(let draft) = presentation else { return 0 }
        return draft.originalAccessBits
    }

    var permissionPreservedBits: UInt32 {
        guard case .permissions(let draft) = presentation else { return 0 }
        return draft.preservedBits
    }

    var permissionErrorMessage: String? {
        guard case .permissions(let draft) = presentation else { return nil }
        return draft.errorMessage
    }

    var createFolderNameBinding: Binding<String> {
        Binding(
            get: {
                guard case .createFolder(let draft) = presentation else { return "" }
                return draft.name
            },
            set: { name in
                guard case .createFolder(var draft) = presentation else { return }
                draft.name = name
                presentation = .createFolder(draft)
            }
        )
    }

    var renameNameBinding: Binding<String> {
        Binding(
            get: {
                guard case .rename(let draft) = presentation else { return "" }
                return draft.name
            },
            set: { name in
                guard case .rename(var draft) = presentation else { return }
                draft.name = name
                presentation = .rename(draft)
            }
        )
    }

    var moveDestinationBinding: Binding<String> {
        Binding(
            get: {
                guard case .move(let draft) = presentation else { return "" }
                return draft.destinationDirectory
            },
            set: { destination in
                guard case .move(var draft) = presentation else { return }
                draft.destinationDirectory = destination
                presentation = .move(draft)
            }
        )
    }

    var permissionDraftBinding: Binding<RemoteFilePermissionDraft> {
        Binding(
            get: {
                guard case .permissions(let draft) = presentation else {
                    return RemoteFilePermissionDraft(accessBits: 0)
                }
                return draft.permissions
            },
            set: { permissions in
                guard case .permissions(var draft) = presentation else { return }
                draft.permissions = permissions
                presentation = .permissions(draft)
            }
        )
    }

    func dismissPresentation() {
        presentation = nil
    }

    func handlePendingToolbarCommand() {
        guard let command = browser.pendingToolbarCommand,
              command.serverId == server.id,
              command.tabId == fileTab.id else {
            return
        }

        switch command.action {
        case .upload(let destinationPath):
            beginUpload(to: destinationPath)
        case .createFolder(let destinationPath):
            beginCreateFolder(in: destinationPath)
        }

        browser.consumeToolbarCommand(command)
    }

    @ViewBuilder
    func browserActionMenu(currentPath: String) -> some View {
        Button {
            beginUpload(to: currentPath)
        } label: {
            Label(String(localized: "Upload…"), systemImage: "square.and.arrow.up")
        }

        Button {
            beginCreateFolder(in: currentPath)
        } label: {
            Label(String(localized: "New Folder…"), systemImage: "folder.badge.plus")
        }

        Divider()

        Button {
            copyPathToClipboard(currentPath)
        } label: {
            Label(String(localized: "Copy Path"), systemImage: "document.on.document")
        }
    }

    @ViewBuilder
    func entryActionMenu(_ entry: RemoteFileEntry) -> some View {
        switch entry.type {
        case .directory:
            Button {
                Task { await browser.openDirectory(entry, in: fileTab, server: server) }
            } label: {
                Label(String(localized: "Open"), systemImage: "folder")
            }

            Button {
                beginUpload(to: entry.path)
            } label: {
                Label(String(localized: "Upload…"), systemImage: "square.and.arrow.up")
            }

            Button {
                beginCreateFolder(in: entry.path)
            } label: {
                Label(String(localized: "New Folder…"), systemImage: "folder.badge.plus")
            }

            permissionMenuAction(for: entry)

        case .file, .other, .symlink:
            Button {
                previewEntry(entry)
            } label: {
                Label(String(localized: "Open"), systemImage: "doc.text")
            }

            Button {
                beginDownload(entry)
            } label: {
                Label(String(localized: "Download…"), systemImage: "arrow.down.circle")
            }

            Button {
                beginShare(entry)
            } label: {
                Label(String(localized: "Share…"), systemImage: "square.and.arrow.up")
            }

            Button {
                beginUpload(to: RemoteFilePath.parent(of: entry.path))
            } label: {
                Label(String(localized: "Upload Here…"), systemImage: "square.and.arrow.up")
            }

            Button {
                beginCreateFolder(in: RemoteFilePath.parent(of: entry.path))
            } label: {
                Label(String(localized: "New Folder Here…"), systemImage: "folder.badge.plus")
            }

            permissionMenuAction(for: entry)
        }

        Divider()

        renameAndMoveMenuActions(for: entry)
        deleteMenuAction(for: entry)

        Divider()

        clipboardMenuActions(for: entry)
    }

    @ViewBuilder
    func inspectorActionMenu(_ entry: RemoteFileEntry) -> some View {
        if entry.type != .directory {
            Button {
                beginDownload(entry)
            } label: {
                Label(String(localized: "Download…"), systemImage: "arrow.down.circle")
            }

            Button {
                beginShare(entry)
            } label: {
                Label(String(localized: "Share…"), systemImage: "square.and.arrow.up")
            }

            Divider()
        }

        permissionMenuAction(for: entry)
        renameAndMoveMenuActions(for: entry)

        Divider()

        clipboardMenuActions(for: entry)

        Divider()

        deleteMenuAction(for: entry)
    }

    @ViewBuilder
    func permissionMenuAction(for entry: RemoteFileEntry) -> some View {
        if canEditPermissions(for: entry) {
            Button {
                beginEditPermissions(entry)
            } label: {
                Label(String(localized: "Permissions…"), systemImage: "lock.shield")
            }
        }
    }

    @ViewBuilder
    func renameAndMoveMenuActions(for entry: RemoteFileEntry) -> some View {
        Button {
            beginRename(entry)
        } label: {
            Label(String(localized: "Rename…"), systemImage: "pencil")
        }

        Button {
            beginMove(entry)
        } label: {
            Label(String(localized: "Move…"), systemImage: "arrow.right.circle")
        }
    }

    @ViewBuilder
    func clipboardMenuActions(for entry: RemoteFileEntry) -> some View {
        Button {
            Clipboard.copy(entry.name)
        } label: {
            Label(String(localized: "Copy Name"), systemImage: "textformat")
        }

        Button {
            copyPathToClipboard(entry.path)
        } label: {
            Label(String(localized: "Copy Path"), systemImage: "document.on.document")
        }
    }

    func deleteMenuAction(for entry: RemoteFileEntry) -> some View {
        Button(role: .destructive) {
            requestDelete([entry])
        } label: {
            Label(String(localized: "Delete"), systemImage: "trash")
        }
    }

    func beginUpload(to remotePath: String) {
        platformBeginUpload(to: remotePath)
    }

    func beginDownload(_ entry: RemoteFileEntry) {
        guard entry.type != .directory else { return }
        platformBeginDownload(entry)
    }

    func beginShare(_ entry: RemoteFileEntry) {
        guard entry.type != .directory else { return }

        cleanupShareItem()

        performTransfer(
            title: String(localized: "Sharing"),
            initialMessage: String(localized: "Preparing remote file."),
            successMessage: String(localized: "Share sheet ready.")
        ) {
            let temporaryURL = try browser.makeTemporaryTransferFileURL(for: entry, in: fileTab)
            do {
                try await browser.downloadFile(
                    at: entry.path,
                    to: temporaryURL,
                    server: server
                )
            } catch {
                browser.removeTemporaryTransferFile(at: temporaryURL, in: fileTab)
                throw error
            }

            await MainActor.run {
                presentation = .share(RemoteFileShareItem(
                    sourceURL: temporaryURL,
                    title: entry.name
                ))
            }
        }
    }

    func beginCreateFolder(in remotePath: String) {
        platformBeginCreateFolder(in: remotePath)
    }

    func beginRename(_ entry: RemoteFileEntry) {
        platformBeginRename(entry)
    }

    func beginMove(_ entry: RemoteFileEntry) {
        presentation = .move(.init(
            entry: entry,
            destinationDirectory: RemoteFilePath.parent(of: entry.path)
        ))
    }

    func beginEditPermissions(_ entry: RemoteFileEntry) {
        guard canEditPermissions(for: entry), let permissions = entry.permissions else { return }
        presentation = .permissions(.init(
            entry: entry,
            permissions: RemoteFilePermissionDraft(accessBits: permissions),
            originalAccessBits: permissions & 0o777,
            preservedBits: entry.specialPermissionBits,
            fileTypeBits: permissions & UInt32(LIBSSH2_SFTP_S_IFMT)
        ))
    }

    func canEditPermissions(for entry: RemoteFileEntry) -> Bool {
        guard entry.permissions != nil else { return false }
        switch entry.type {
        case .symlink:
            return false
        case .file, .directory, .other:
            return true
        }
    }

    func previewEntry(_ entry: RemoteFileEntry) {
        Task {
            await browser.activate(entry, in: fileTab, server: server)
            await platformDidActivatePreviewEntry(entry)
        }
    }

    func handleUploadSelection(_ result: Result<[URL], Error>, toPresentedDestination destinationPath: String) {
        guard case .upload(let currentDestination) = presentation,
              currentDestination == destinationPath else { return }
        dismissPresentation()
        handleUploadSelection(result, to: destinationPath)
    }

    func handleUploadSelection(_ result: Result<[URL], Error>, to destinationPath: String) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            beginUploadFlow(
                urls: urls,
                to: destinationPath,
                initialMessage: String(localized: "Preparing files for upload.")
            )
        case .failure(let error):
            presentOperationError(error)
        }
    }

    func handleDownloadExportCompletion(_ result: Result<URL, Error>) {
        guard case .downloadExport(let export) = presentation else { return }
        let transferID = export.transferID
        let noticeID = transferID.uuidString
        operationCoordinator.dismiss(transferID)

        switch result {
        case .success:
            cleanupDownloadExport()
            noticeHost.show(
                NoticeItem(
                    id: noticeID,
                    lane: .bottomOperation,
                    level: .success,
                    leading: .icon("checkmark.circle.fill"),
                    title: String(localized: "Downloading"),
                    message: String(localized: "Export complete."),
                    lifetime: .autoDismiss(.seconds(2))
                )
            )
        case .failure(let error):
            let nsError = error as NSError
            if nsError.code == NSUserCancelledError {
                handleDownloadExportCancellation()
            } else {
                cleanupDownloadExport()
                noticeHost.show(
                    NoticeItem(
                        id: noticeID,
                        lane: .bottomOperation,
                        level: .error,
                        leading: .icon("xmark.octagon.fill"),
                        title: String(localized: "Downloading"),
                        message: remoteOperationErrorMessage(for: error),
                        dismissAction: { noticeHost.dismiss(id: noticeID) }
                    )
                )
            }
        }

        pendingDownloadTransferID = nil
    }

    func handleDownloadExportCancellation() {
        guard case .downloadExport(let export) = presentation else { return }
        cleanupDownloadExport()
        operationCoordinator.dismiss(export.transferID)
        pendingDownloadTransferID = nil
    }

    func beginUploadFlow(urls: [URL], to destinationPath: String, initialMessage: String) {
        let browser = browser
        let fileTab = fileTab
        let server = server
        operationCoordinator.start(
            kind: .upload,
            title: String(localized: "Uploading"),
            initialMessage: initialMessage,
            successMessage: String(localized: "Upload complete.")
        ) { onProgress in
            try await browser.uploadFilesResolvingConflicts(
                at: urls,
                to: destinationPath,
                in: fileTab,
                server: server,
                onProgress: onProgress
            )
        }
    }

    func handleCurrentDirectoryDrop(_ providers: [NSItemProvider], to destinationPath: String) -> Bool {
        if handleRemoteDrop(providers, to: destinationPath) {
            return true
        }

        return handleLocalDrop(providers, to: destinationPath)
    }

    func handleLocalDrop(_ providers: [NSItemProvider], to destinationPath: String) -> Bool {
        let fileURLProviders = providers.filter { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileURLProviders.isEmpty else { return false }

        Task {
            do {
                let urls = try await loadDroppedURLs(from: fileURLProviders)
                await MainActor.run {
                    beginUploadFlow(
                        urls: urls,
                        to: destinationPath,
                        initialMessage: String(localized: "Preparing dropped files.")
                    )
                }
            } catch {
                await MainActor.run {
                    presentOperationError(error)
                }
            }
        }

        return true
    }

    func handleRemoteDrop(_ providers: [NSItemProvider], to destinationPath: String) -> Bool {
        let remoteProviders = providers.filter { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.vvtermRemoteFileEntry.identifier)
        }
        guard !remoteProviders.isEmpty else { return false }

        performTransfer(
            title: String(localized: "Transferring"),
            initialMessage: String(localized: "Preparing remote items."),
            successMessage: String(localized: "Transfer complete.")
        ) { onProgress in
            let payloads = try await loadDroppedRemotePayloads(from: remoteProviders)
            try await browser.transferDroppedRemoteItems(
                payloads,
                to: destinationPath,
                destinationTab: fileTab,
                destinationServer: server,
                onProgress: onProgress
            )
        }

        return true
    }

    func handleFolderDrop(_ providers: [NSItemProvider], to entry: RemoteFileEntry) -> Bool {
        guard entry.type == .directory else { return false }
        return handleCurrentDirectoryDrop(providers, to: entry.path)
    }

    func dragItemProvider(for entry: RemoteFileEntry) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = dragSuggestedName(for: [entry])
        registerRemoteDragPayload(for: [entry], in: provider)
        registerFileRepresentation(for: entry, in: provider)
        return provider
    }

    func registerRemoteDragPayload(for entries: [RemoteFileEntry], in provider: NSItemProvider) {
        let encodedPayload = Result {
            try JSONEncoder().encode(RemoteFileDragPayload(serverId: server.id, entries: entries))
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.vvtermRemoteFileEntry.identifier,
            visibility: .ownProcess
        ) { completion in
            do {
                let data = try encodedPayload.get()
                completion(data, nil)
            } catch {
                completion(nil, error)
            }
            return nil
        }
    }

    func registerFileRepresentation(for entry: RemoteFileEntry, in provider: NSItemProvider) {
        let typeIdentifier = dragFileTypeIdentifier(for: entry)
        provider.registerFileRepresentation(
            forTypeIdentifier: typeIdentifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)

            let exportTask = Task {
                do {
                    let temporaryURL = try await browser.temporaryStorage.prepareDragExport(
                        for: entry
                    ) { temporaryURL in
                        try await browser.downloadItem(entry, to: temporaryURL, server: server)
                        guard !progress.isCancelled else { throw CancellationError() }
                    }
                    completion(temporaryURL, false, nil)
                    progress.completedUnitCount = 1
                } catch {
                    completion(nil, false, error)
                }
            }
            progress.cancellationHandler = {
                exportTask.cancel()
            }

            return progress
        }
    }

    func dragFileTypeIdentifier(for entry: RemoteFileEntry) -> String {
        if entry.type == .directory {
            return UTType.folder.identifier
        }

        let pathExtension = URL(fileURLWithPath: entry.name).pathExtension
        return UTType(filenameExtension: pathExtension)?.identifier ?? UTType.data.identifier
    }

    func loadDroppedURLs(from providers: [NSItemProvider]) async throws -> [URL] {
        var urls: [URL] = []

        for provider in providers {
            urls.append(try await loadDroppedURL(from: provider))
        }

        let uniqueURLs = Array(NSOrderedSet(array: urls).compactMap { $0 as? URL })
        guard !uniqueURLs.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "No valid files or folders were dropped."))
        }
        return uniqueURLs
    }

    func loadDroppedURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }

                if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                    return
                }

                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                    return
                }

                if let text = item as? String,
                   let url = URL(string: text) {
                    continuation.resume(returning: url)
                    return
                }

                continuation.resume(
                    throwing: RemoteFileBrowserError.failed(
                        String(localized: "The dropped item could not be resolved to a local file or folder.")
                    )
                )
            }
        }
    }

    func loadDroppedRemotePayloads(from providers: [NSItemProvider]) async throws -> [RemoteFileDragPayload] {
        var payloads: [RemoteFileDragPayload] = []

        for provider in providers {
            payloads.append(try await loadDroppedRemotePayload(from: provider))
        }

        guard payloads.contains(where: { !$0.entries.isEmpty }) else {
            throw RemoteFileBrowserError.failed(String(localized: "No valid remote items were dropped."))
        }
        return payloads
    }

    func loadDroppedRemotePayload(from provider: NSItemProvider) async throws -> RemoteFileDragPayload {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.vvtermRemoteFileEntry.identifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data else {
                    continuation.resume(
                        throwing: RemoteFileBrowserError.failed(
                            String(localized: "The dragged remote item could not be decoded.")
                        )
                    )
                    return
                }

                Task { @MainActor in
                    do {
                        let payload = try JSONDecoder().decode(RemoteFileDragPayload.self, from: data)
                        continuation.resume(returning: payload)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func dragSuggestedName(for entries: [RemoteFileEntry]) -> String? {
        guard entries.count > 1 else {
            guard let name = entries.first?.name, !name.isEmpty else { return nil }
            return name
        }

        return String(
            format: String(localized: "%lld items"),
            Int64(entries.count)
        )
    }

    func createFolder() {
        guard case .createFolder(var draft) = presentation else { return }
        guard !draft.isSubmitting else { return }
        guard !trimmedNewFolderName.isEmpty else {
            resetNewFolderPrompt()
            return
        }
        draft.isSubmitting = true
        presentation = .createFolder(draft)
        let destinationPath = draft.destinationPath
        let folderNameInput = draft.name

        performOperation(
            operation: {
                let folderName = try RemoteFilePathPolicy.validatedName(
                    folderNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                try await browser.createDirectory(
                    named: folderName,
                    in: destinationPath,
                    tab: fileTab,
                    server: server
                )
            },
            onSuccess: { _ in
                resetNewFolderPrompt()
            },
            onFailure: { error in
                guard case .createFolder(var current) = presentation,
                      current.destinationPath == destinationPath else { return }
                current.isSubmitting = false
                presentation = .createFolder(current)
                presentOperationError(error)
            }
        )
    }

    func renameEntry() {
        guard case .rename(var draft) = presentation, !draft.isSubmitting else { return }
        draft.isSubmitting = true
        presentation = .rename(draft)
        let entry = draft.entry
        let nameInput = draft.name

        performOperation(
            operation: {
                let newName = try RemoteFilePathPolicy.validatedName(
                    nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                guard newName != entry.name else {
                    return false
                }

                let destinationPath = RemoteFilePath.appending(
                    try RemoteFileLeaf(validating: newName),
                    to: RemoteFilePath.parent(of: entry.path)
                )
                try await browser.renameItem(
                    at: entry.path,
                    to: destinationPath,
                    in: fileTab,
                    server: server
                )
                return true
            },
            onSuccess: { _ in
                resetRenamePrompt()
            },
            onFailure: { error in
                guard case .rename(var current) = presentation,
                      current.entry.id == entry.id else { return }
                current.isSubmitting = false
                presentation = .rename(current)
                presentOperationError(error)
            }
        )
    }

    func moveEntry() {
        guard case .move(var draft) = presentation, !draft.isSubmitting else { return }
        draft.isSubmitting = true
        presentation = .move(draft)
        let entry = draft.entry
        let destinationInput = draft.destinationDirectory

        performOperation(
            operation: {
                let sourceDirectory = RemoteFilePath.parent(of: entry.path)
                let destinationDirectory = try RemoteFilePathPolicy.validatedDirectoryPath(
                    destinationInput,
                    relativeTo: sourceDirectory
                )
                let entryLeaf = try RemoteFileLeaf(validating: entry.name)
                let destinationPath = RemoteFilePath.appending(entryLeaf, to: destinationDirectory)

                guard destinationPath != entry.path else {
                    return false
                }

                try await browser.renameItem(
                    at: entry.path,
                    to: destinationPath,
                    in: fileTab,
                    server: server
                )
                return true
            },
            onSuccess: { _ in
                resetMovePrompt()
            },
            onFailure: { error in
                guard case .move(var current) = presentation,
                      current.entry.id == entry.id else { return }
                current.isSubmitting = false
                presentation = .move(current)
                presentOperationError(error)
            }
        )
    }

    func deleteEntry() {
        guard case .delete(let entry) = presentation else { return }
        dismissPresentation()

        deleteEntries([entry])
    }

    func deleteEntries(_ entries: [RemoteFileEntry]) {
        guard !entries.isEmpty else { return }

        performOperation {
            for entry in entries {
                try await browser.deleteItem(
                    at: entry.path,
                    in: fileTab,
                    server: server,
                    type: entry.type
                )
            }
        }
    }

    func requestDelete(_ entries: [RemoteFileEntry]) {
        guard !entries.isEmpty else { return }
        platformRequestDelete(entries)
    }

    func resetNewFolderPrompt() {
        if case .createFolder = presentation { dismissPresentation() }
    }

    func resetRenamePrompt() {
        if case .rename = presentation { dismissPresentation() }
    }

    func resetMovePrompt() {
        if case .move = presentation { dismissPresentation() }
    }

    func applyPermissions() {
        guard case .permissions(var draft) = presentation, !draft.isSubmitting else { return }
        draft.errorMessage = nil
        draft.isSubmitting = true
        presentation = .permissions(draft)
        let entry = draft.entry
        let requestedPermissions = draft.fileTypeBits | draft.preservedBits | draft.permissions.accessBits

        performOperation(
            operation: {
                try await browser.setPermissions(entry, permissions: requestedPermissions, in: fileTab, server: server)
            },
            onSuccess: { _ in
                resetPermissionEditor()
            },
            onFailure: { error in
                guard case .permissions(var current) = presentation,
                      current.entry.id == entry.id else { return }
                current.isSubmitting = false
                current.errorMessage = remoteOperationErrorMessage(for: error)
                presentation = .permissions(current)
            }
        )
    }

    func resetPermissionEditor() {
        if case .permissions = presentation { dismissPresentation() }
    }

    func cleanupDownloadExport() {
        if let sourceURL = downloadExportDocument?.sourceURL {
            browser.removeTemporaryTransferFile(at: sourceURL, in: fileTab)
        }
        if case .downloadExport = presentation { dismissPresentation() }
    }

    func cleanupShareItem() {
        guard case .share(let item) = presentation else { return }
        if FileManager.default.fileExists(atPath: item.sourceURL.path) {
            let sourceURL = item.sourceURL
            browser.removeTemporaryTransferFile(at: sourceURL, in: fileTab)
        }
        dismissPresentation()
    }

    func finishSharing(_ item: RemoteFileShareItem) {
        guard case .share(let current) = presentation, current.id == item.id else { return }
        cleanupShareItem()
    }

    func currentFolderTitle(for path: String) -> String {
        RemoteFilePath.breadcrumbs(for: path).last?.title ?? "/"
    }

    func itemCountLabel(for count: Int) -> String {
        count == 1
            ? String(format: String(localized: "%lld item"), Int64(count))
            : String(format: String(localized: "%lld items"), Int64(count))
    }

    func modifiedLabel(for entry: RemoteFileEntry) -> String {
        guard let modifiedAt = entry.modifiedAt else { return "—" }
        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    func deleteAlertTitle(for entry: RemoteFileEntry) -> String {
        switch entry.type {
        case .directory:
            return String(localized: "Delete Folder?")
        case .file:
            return String(localized: "Delete File?")
        case .symlink, .other:
            return String(localized: "Delete Item?")
        }
    }

    func sizeLabel(for entry: RemoteFileEntry) -> String {
        guard entry.type != .directory, let size = entry.size else { return "—" }
        return RemoteFileByteCountFormatter.string(from: size)
    }

    func kindLabel(for entry: RemoteFileEntry) -> String {
        switch entry.type {
        case .directory:
            return String(localized: "Folder")
        case .symlink:
            return String(localized: "Symlink")
        case .other:
            return String(localized: "Document")
        case .file:
            let ext = URL(fileURLWithPath: entry.name).pathExtension.lowercased()
            switch ext {
            case "yaml", "yml":
                return String(localized: "YAML Document")
            case "json":
                return String(localized: "JSON Document")
            case "md":
                return String(localized: "Markdown Document")
            case "txt", "log":
                return String(localized: "Text Document")
            case "swift":
                return String(localized: "Swift Source")
            case "sh", "bash", "zsh":
                return String(localized: "Shell Script")
            case "png", "jpg", "jpeg", "gif", "webp", "heic":
                return String(localized: "Image")
            case "zip", "tar", "gz", "tgz", "xz", "bz2":
                return String(localized: "Archive")
            default:
                return String(localized: "Document")
            }
        }
    }

}
