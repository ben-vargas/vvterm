import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct RemoteFileBrowserView: View {
    let server: Server
    let initialPath: String?

    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var browser = RemoteFileBrowserManager.shared
    @AppStorage("terminalThemeName") var terminalThemeName = "Aizen Dark"
    @AppStorage("terminalThemeNameLight") var terminalThemeNameLight = "Aizen Light"
    @AppStorage("terminalUsePerAppearanceTheme") var usePerAppearanceTheme = true
    @State var presentedPreviewPath: String?
    @State var uploadDestinationPath: String?
    @State var downloadExportDocument: RemoteFileDownloadDocument?
    @State var downloadExportFilename = ""
    @State var isDownloadExporterPresented = false
    @State var shareItem: RemoteFileShareItem?
    @State var iOSSearchQuery = ""
    @State var newFolderDestinationPath: String?
    @State var newFolderName = ""
    @State var isCreateFolderSubmitting = false
    @State var renameTargetEntry: RemoteFileEntry?
    @State var renameName = ""
    @State var isRenameSubmitting = false
    @State var moveTargetEntry: RemoteFileEntry?
    @State var moveDestinationDirectory = ""
    @State var isMoveSubmitting = false
    @State var deleteTargetEntry: RemoteFileEntry?
    @State var permissionTargetEntry: RemoteFileEntry?
    @State var permissionDraft = RemoteFilePermissionDraft(accessBits: 0)
    @State var permissionOriginalAccessBits: UInt32 = 0
    @State var permissionPreservedBits: UInt32 = 0
    @State var isPermissionSubmitting = false
    @State var operationErrorMessage: String?
    @State var transferStatus: TransferStatus?
    @State var isDropTargeted = false
    #if os(macOS)
    @State var macOSSelectedPaths: Set<String> = []
    @State var macOSTitlebarHeight: CGFloat = 0
    #else
    @FocusState var iOSSearchFieldFocused: Bool
    #endif

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

    struct TransferStatus: Identifiable {
        enum Phase {
            case running
            case succeeded
        }

        let id: UUID
        let title: String
        let message: String
        let completedUnitCount: Int?
        let totalUnitCount: Int?
        let phase: Phase
    }

    var snapshot: Snapshot {
        let entries = browser.entries(for: server.id)
        let viewerPayload = browser.viewerPayload(for: server.id)
        let selectedPath = browser.selectedEntryPath(for: server.id) ?? viewerPayload?.entry.path
        let selectedEntry = entries.first(where: { $0.path == selectedPath }) ?? viewerPayload?.entry

        return Snapshot(
            currentPath: browser.currentPath(for: server.id),
            breadcrumbs: browser.breadcrumbs(for: server.id),
            entries: entries,
            selectedEntry: selectedEntry,
            viewerPayload: viewerPayload,
            directoryError: browser.error(for: server.id),
            viewerError: browser.viewerError(for: server.id),
            isLoadingDirectory: browser.isLoading(for: server.id),
            isLoadingViewer: browser.isLoadingViewer(for: server.id),
            sort: browser.sort(for: server.id),
            sortDirection: browser.sortDirection(for: server.id),
            showHiddenFiles: browser.showHiddenFiles(for: server.id),
            isTruncated: browser.isTruncated(for: server.id),
            selectedPath: selectedPath,
            filesystemStatus: browser.filesystemStatus(for: server.id)
        )
    }

    var initialLoadTaskID: String {
        let hasEntries = !snapshot.entries.isEmpty
        return "\(server.id.uuidString):\(initialPath ?? ""):\(hasEntries)"
    }

    var remoteRowDropTypeIdentifiers: [String] {
        [UTType.vvtermRemoteFileEntry.identifier, UTType.fileURL.identifier]
    }

    var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    var terminalThemeBackgroundColor: Color {
        if let color = ThemeColorParser.backgroundColor(for: effectiveThemeName) {
            return color
        }

        if let cachedHex = UserDefaults.standard.string(forKey: "terminalBackgroundColor") {
            return Color.fromHex(cachedHex)
        }

        return colorScheme == .dark ? .black : .white
    }

    init(server: Server, initialPath: String?) {
        self.server = server
        self.initialPath = initialPath
    }

    var body: some View {
        ZStack {
            Group {
                #if os(macOS)
                macOSContent(snapshot)
                #else
                iOSContent(snapshot)
                #endif
            }

            if isDropTargeted {
                RemoteFileDropOverlay()
                    .padding(20)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let transferStatus {
                RemoteFileTransferStatusView(status: transferStatus)
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: initialLoadTaskID) {
            await browser.loadInitialPath(for: server, initialPath: initialPath)
        }
        .fileImporter(
            isPresented: uploadImporterBinding,
            allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: true
        ) { result in
            handleUploadSelection(result)
        }
        .fileExporter(
            isPresented: $isDownloadExporterPresented,
            document: downloadExportDocument,
            contentType: .data,
            defaultFilename: downloadExportFilename
        ) { result in
            handleDownloadExportCompletion(result)
        }
        #if os(macOS)
        .overlay(alignment: .topTrailing) {
            if let shareItem {
                RemoteFileSharePicker(item: shareItem) {
                    finishSharing(shareItem)
                }
                .frame(width: 1, height: 1)
                .padding(.top, 12)
                .padding(.trailing, 12)
            }
        }
        #else
        .sheet(item: $shareItem) { item in
            RemoteFileShareSheet(item: item) {
                finishSharing(item)
            }
        }
        #endif
        #if os(iOS)
        .onDrop(of: remoteRowDropTypeIdentifiers, isTargeted: $isDropTargeted) { providers in
            handleCurrentDirectoryDrop(providers, to: snapshot.currentPath)
        }
        #endif
        #if os(macOS)
        .sheet(isPresented: newFolderPromptBinding, onDismiss: resetNewFolderPrompt) {
            if let destinationPath = newFolderDestinationPath {
                RemoteFileCreateFolderSheet(
                    destinationPath: destinationPath,
                    folderName: $newFolderName,
                    isSubmitting: isCreateFolderSubmitting,
                    onCancel: resetNewFolderPrompt,
                    onCreate: createFolder
                )
                .frame(
                    minWidth: 460,
                    idealWidth: 500,
                    maxWidth: 560,
                    minHeight: 220,
                    idealHeight: 250,
                    maxHeight: 300
                )
            }
        }
        #endif
        #if os(iOS)
        .alert(String(localized: "New Folder"), isPresented: newFolderPromptBinding) {
            TextField(String(localized: "Folder Name"), text: $newFolderName)

            Button(String(localized: "Create")) {
                createFolder()
            }
            .disabled(trimmedNewFolderName.isEmpty || isCreateFolderSubmitting)

            Button(String(localized: "Cancel"), role: .cancel) {
                resetNewFolderPrompt()
            }
        } message: {
            Text(String(localized: "Create a folder in the current remote directory."))
        }
        #endif
        .alert(String(localized: "Files"), isPresented: operationErrorBinding) {
            Button(String(localized: "OK"), role: .cancel) {
                operationErrorMessage = nil
            }
        } message: {
            Text(operationErrorMessage ?? "")
        }
        .sheet(item: $renameTargetEntry, onDismiss: resetRenamePrompt) { entry in
            RemoteFileRenameSheet(
                entry: entry,
                proposedName: $renameName,
                isSubmitting: isRenameSubmitting,
                onCancel: resetRenamePrompt,
                onRename: { renameEntry() }
            )
            #if os(macOS)
            .frame(
                minWidth: 460,
                idealWidth: 500,
                maxWidth: 560,
                minHeight: 220,
                idealHeight: 240,
                maxHeight: 280
            )
            #endif
        }
        .sheet(item: $moveTargetEntry, onDismiss: resetMovePrompt) { entry in
            RemoteFileMoveSheet(
                entry: entry,
                destinationDirectory: $moveDestinationDirectory,
                onLoadDirectories: { path in
                    try await browser.listDirectories(at: path, serverId: server.id)
                },
                isSubmitting: isMoveSubmitting,
                onCancel: resetMovePrompt,
                onMove: moveEntry
            )
            #if os(macOS)
            .frame(
                minWidth: 460,
                idealWidth: 500,
                maxWidth: 560,
                minHeight: 420,
                idealHeight: 520,
                maxHeight: 620
            )
            #endif
        }
        #if os(iOS)
        .sheet(item: $deleteTargetEntry, onDismiss: { deleteTargetEntry = nil }) { entry in
            RemoteFileDeleteConfirmationSheet(
                entry: entry,
                message: deleteAlertMessage(for: entry),
                onCancel: { deleteTargetEntry = nil },
                onDelete: deleteEntry
            )
        }
        #endif
        .sheet(item: $permissionTargetEntry, onDismiss: resetPermissionEditor) { entry in
            RemoteFilePermissionEditorSheet(
                entry: entry,
                draft: $permissionDraft,
                originalAccessBits: permissionOriginalAccessBits,
                preservedBits: permissionPreservedBits,
                isSubmitting: isPermissionSubmitting,
                onCancel: resetPermissionEditor,
                onApply: applyPermissions
            )
            #if os(macOS)
            .frame(
                minWidth: 460,
                idealWidth: 500,
                maxWidth: 560,
                minHeight: 520,
                idealHeight: 580,
                maxHeight: 680
            )
            #endif
        }
        .onChange(of: snapshot.currentPath) { newValue in
            if let destination = newFolderDestinationPath, destination != newValue {
                resetNewFolderPrompt()
            }
            #if os(macOS)
            macOSSelectedPaths.removeAll()
            #endif
        }
        .onChange(of: browser.pendingToolbarCommand?.id) { _ in
            handlePendingToolbarCommand()
        }
        #if os(macOS)
        .onChange(of: snapshot.entries.map(\.id)) { visiblePaths in
            let nextSelection = macOSSelectedPaths.intersection(Set(visiblePaths))
            if nextSelection != macOSSelectedPaths {
                macOSSelectedPaths = nextSelection
            }
        }
        .onChange(of: snapshot.selectedPath) { newValue in
            guard macOSSelectedPaths.count <= 1 else { return }

            guard let newValue, snapshot.entries.contains(where: { $0.id == newValue }) else {
                if !macOSSelectedPaths.isEmpty {
                    macOSSelectedPaths = []
                }
                return
            }

            if macOSSelectedPaths != [newValue] {
                macOSSelectedPaths = [newValue]
            }
        }
        #endif
    }

    var uploadImporterBinding: Binding<Bool> {
        Binding(
            get: { uploadDestinationPath != nil },
            set: { isPresented in
                if !isPresented {
                    uploadDestinationPath = nil
                }
            }
        )
    }

    var newFolderPromptBinding: Binding<Bool> {
        Binding(
            get: { newFolderDestinationPath != nil },
            set: { isPresented in
                if !isPresented {
                    resetNewFolderPrompt()
                }
            }
        )
    }

    var renamePromptBinding: Binding<Bool> {
        Binding(
            get: { renameTargetEntry != nil },
            set: { isPresented in
                if !isPresented {
                    resetRenamePrompt()
                }
            }
        )
    }

    var deletePromptBinding: Binding<Bool> {
        Binding(
            get: { deleteTargetEntry != nil },
            set: { isPresented in
                if !isPresented {
                    deleteTargetEntry = nil
                }
            }
        )
    }

    func deleteAlertMessage(for entry: RemoteFileEntry) -> String {
        let itemName = entry.name.isEmpty ? entry.path : entry.name
        return String(
            format: String(localized: "This will permanently remove \"%@\" from the remote server. This cannot be undone."),
            itemName
        )
    }

    var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { operationErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    operationErrorMessage = nil
                }
            }
        )
    }

    func remoteOperationErrorMessage(for error: Error) -> String {
        RemoteFileBrowserError.map(error).errorDescription ?? error.localizedDescription
    }

    @MainActor
    func presentOperationError(_ error: Error) {
        transferStatus = nil
        operationErrorMessage = remoteOperationErrorMessage(for: error)
    }

    @MainActor
    func beginTransferStatus(
        id: UUID,
        title: String,
        message: String,
        completedUnitCount: Int? = nil,
        totalUnitCount: Int? = nil
    ) {
        transferStatus = TransferStatus(
            id: id,
            title: title,
            message: message,
            completedUnitCount: completedUnitCount,
            totalUnitCount: totalUnitCount,
            phase: .running
        )
    }

    @MainActor
    func updateTransferStatus(
        id: UUID,
        title: String,
        message: String,
        completedUnitCount: Int,
        totalUnitCount: Int
    ) {
        guard transferStatus?.id == id else { return }
        transferStatus = TransferStatus(
            id: id,
            title: title,
            message: message,
            completedUnitCount: completedUnitCount,
            totalUnitCount: totalUnitCount,
            phase: .running
        )
    }

    @MainActor
    func completeTransferStatus(id: UUID, title: String, message: String) {
        guard transferStatus?.id == id else { return }
        transferStatus = TransferStatus(
            id: id,
            title: title,
            message: message,
            completedUnitCount: transferStatus?.totalUnitCount,
            totalUnitCount: transferStatus?.totalUnitCount,
            phase: .succeeded
        )

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard transferStatus?.id == id else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                transferStatus = nil
            }
        }
    }

    func performTransfer(
        title: String,
        initialMessage: String,
        successMessage: String,
        operation: @escaping (@escaping @MainActor (RemoteFileBrowserManager.TransferProgress) -> Void) async throws -> Void
    ) {
        let transferID = UUID()

        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.2)) {
                beginTransferStatus(
                    id: transferID,
                    title: title,
                    message: initialMessage
                )
            }
        }

        Task {
            do {
                try await operation { progress in
                    let itemName = progress.currentItemName.isEmpty
                        ? String(localized: "item")
                        : progress.currentItemName
                    updateTransferStatus(
                        id: transferID,
                        title: title,
                        message: String(
                            format: String(localized: "%lld of %lld: %@"),
                            Int64(progress.completedUnitCount),
                            Int64(progress.totalUnitCount),
                            itemName
                        ),
                        completedUnitCount: progress.completedUnitCount,
                        totalUnitCount: progress.totalUnitCount
                    )
                }

                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        completeTransferStatus(
                            id: transferID,
                            title: title,
                            message: successMessage
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    if transferStatus?.id == transferID {
                        transferStatus = nil
                    }
                    presentOperationError(error)
                }
            }
        }
    }

    func performTransfer(
        title: String,
        initialMessage: String,
        successMessage: String,
        operation: @escaping () async throws -> Void
    ) {
        performTransfer(
            title: title,
            initialMessage: initialMessage,
            successMessage: successMessage
        ) { _ in
            try await operation()
        }
    }

    func performOperation(
        onFailure: (@MainActor (Error) -> Void)? = nil,
        operation: @escaping () async throws -> Void
    ) {
        Task {
            do {
                try await operation()
            } catch {
                await MainActor.run {
                    if let onFailure {
                        onFailure(error)
                    } else {
                        presentOperationError(error)
                    }
                }
            }
        }
    }

    func performOperation<Result>(
        operation: @escaping () async throws -> Result,
        onSuccess: @escaping @MainActor (Result) -> Void,
        onFailure: (@MainActor (Error) -> Void)? = nil
    ) {
        Task {
            do {
                let result = try await operation()
                await MainActor.run {
                    onSuccess(result)
                }
            } catch {
                await MainActor.run {
                    if let onFailure {
                        onFailure(error)
                    } else {
                        presentOperationError(error)
                    }
                }
            }
        }
    }

    var trimmedNewFolderName: String {
        newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedRenameName: String {
        renameName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func handlePendingToolbarCommand() {
        guard let command = browser.pendingToolbarCommand, command.serverId == server.id else { return }

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
            Clipboard.copy(currentPath)
        } label: {
            Label(String(localized: "Copy Path"), systemImage: "document.on.document")
        }
    }

    @ViewBuilder
    func entryActionMenu(_ entry: RemoteFileEntry) -> some View {
        switch entry.type {
        case .directory:
            Button {
                Task { await browser.openDirectory(entry, serverId: server.id) }
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
            Clipboard.copy(entry.path)
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
        #if os(macOS)
        presentMacOSUploadPanel(for: remotePath)
        #else
        uploadDestinationPath = remotePath
        #endif
    }

    func beginDownload(_ entry: RemoteFileEntry) {
        guard entry.type != .directory else { return }

        #if os(macOS)
        presentMacOSDownloadPanel(for: entry)
        #else
        cleanupDownloadExport()

        performTransfer(
            title: String(localized: "Downloading"),
            initialMessage: String(localized: "Preparing remote file."),
            successMessage: String(localized: "Download ready to export.")
        ) {
            let temporaryURL = try temporaryDownloadURL(for: entry)
            try await browser.downloadFile(
                at: entry.path,
                to: temporaryURL,
                serverId: server.id
            )

            await MainActor.run {
                downloadExportDocument = RemoteFileDownloadDocument(sourceURL: temporaryURL)
                downloadExportFilename = entry.name
                isDownloadExporterPresented = true
            }
        }
        #endif
    }

    func beginShare(_ entry: RemoteFileEntry) {
        guard entry.type != .directory else { return }

        cleanupShareItem()

        performTransfer(
            title: String(localized: "Sharing"),
            initialMessage: String(localized: "Preparing remote file."),
            successMessage: String(localized: "Share sheet ready.")
        ) {
            let temporaryURL = try temporaryDownloadURL(for: entry)
            try await browser.downloadFile(
                at: entry.path,
                to: temporaryURL,
                serverId: server.id
            )

            await MainActor.run {
                shareItem = RemoteFileShareItem(
                    sourceURL: temporaryURL,
                    title: entry.name
                )
            }
        }
    }

    func beginCreateFolder(in remotePath: String) {
        newFolderDestinationPath = remotePath
        #if os(macOS)
        newFolderName = String(localized: "New Folder")
        #else
        newFolderName = ""
        #endif
        isCreateFolderSubmitting = false
    }

    func beginRename(_ entry: RemoteFileEntry) {
        renameTargetEntry = entry
        renameName = entry.name
        isRenameSubmitting = false
    }

    func beginMove(_ entry: RemoteFileEntry) {
        moveTargetEntry = entry
        moveDestinationDirectory = RemoteFilePath.parent(of: entry.path)
        isMoveSubmitting = false
    }

    func beginEditPermissions(_ entry: RemoteFileEntry) {
        guard canEditPermissions(for: entry), let permissions = entry.permissions else { return }
        permissionTargetEntry = entry
        permissionDraft = RemoteFilePermissionDraft(accessBits: permissions)
        permissionOriginalAccessBits = permissions & 0o777
        permissionPreservedBits = entry.specialPermissionBits
        isPermissionSubmitting = false
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
            await browser.activate(entry, serverId: server.id)
            #if os(iOS)
            if browser.selectedEntryPath(for: server.id) == entry.path {
                await MainActor.run {
                    presentedPreviewPath = entry.path
                }
            }
            #endif
        }
    }

    func handleUploadSelection(_ result: Result<[URL], Error>) {
        guard let destinationPath = uploadDestinationPath else { return }
        uploadDestinationPath = nil

        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            performTransfer(
                title: String(localized: "Uploading"),
                initialMessage: String(localized: "Preparing files for upload."),
                successMessage: String(localized: "Upload complete.")
            ) { onProgress in
                try await browser.uploadFiles(
                    at: urls,
                    to: destinationPath,
                    serverId: server.id,
                    onProgress: onProgress
                )
            }
        case .failure(let error):
            presentOperationError(error)
        }
    }

    func handleDownloadExportCompletion(_ result: Result<URL, Error>) {
        isDownloadExporterPresented = false

        switch result {
        case .success:
            cleanupDownloadExport()
            if let transferStatus, transferStatus.phase == .succeeded {
                completeTransferStatus(
                    id: transferStatus.id,
                    title: transferStatus.title,
                    message: String(localized: "Export complete.")
                )
            }
        case .failure(let error):
            let nsError = error as NSError
            cleanupDownloadExport()
            guard nsError.code != NSUserCancelledError else { return }
            presentOperationError(error)
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

        performTransfer(
            title: String(localized: "Uploading"),
            initialMessage: String(localized: "Preparing dropped files."),
            successMessage: String(localized: "Upload complete.")
        ) { onProgress in
            let urls = try await loadDroppedURLs(from: fileURLProviders)
            try await browser.uploadFiles(
                at: urls,
                to: destinationPath,
                serverId: server.id,
                onProgress: onProgress
            )
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
            try await transferDroppedRemoteItems(
                payloads,
                to: destinationPath,
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
        let preparedTemporaryURL = Result {
            try temporaryDragExportURL(for: entry)
        }
        provider.registerFileRepresentation(
            forTypeIdentifier: typeIdentifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)

            Task {
                do {
                    let temporaryURL = try preparedTemporaryURL.get()
                    try await browser.downloadItem(entry, to: temporaryURL, serverId: server.id)
                    guard !progress.isCancelled else {
                        completion(nil, false, CancellationError())
                        return
                    }
                    completion(temporaryURL, false, nil)
                    progress.completedUnitCount = 1
                } catch {
                    completion(nil, false, error)
                }
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

    func temporaryDragExportURL(for entry: RemoteFileEntry) throws -> URL {
        let exportDirectory = try temporaryDragExportDirectory()
        let fallbackName = entry.type == .directory ? "Folder" : "download"
        let filename = entry.name.isEmpty ? fallbackName : entry.name
        return exportDirectory.appendingPathComponent(filename, isDirectory: entry.type == .directory)
    }

    func temporaryDragExportDirectory(named folderName: String? = nil) throws -> URL {
        let fileManager = FileManager.default
        let rootDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("VVTermDraggedItems", isDirectory: true)
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let trimmedFolderName = folderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let directoryName = trimmedFolderName.isEmpty ? UUID().uuidString : trimmedFolderName
        let exportDirectory = rootDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        return exportDirectory
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

        var seenPaths: Set<String> = []
        let uniquePayloads: [RemoteFileDragPayload] = payloads.compactMap { payload in
            let uniqueEntries = payload.entries.filter { entry in
                seenPaths.insert(entry.path).inserted
            }
            guard !uniqueEntries.isEmpty else { return nil }
            return RemoteFileDragPayload(serverId: payload.serverId, entries: uniqueEntries)
        }
        guard !uniquePayloads.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "No valid remote items were dropped."))
        }
        return uniquePayloads
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

    func moveDroppedRemoteItems(
        _ payloads: [RemoteFileDragPayload],
        to destinationDirectoryPath: String,
        onProgress: (@MainActor (RemoteFileBrowserManager.TransferProgress) -> Void)? = nil
    ) async throws {
        let uniqueEntries = payloads
            .flatMap(\.entries)
            .reduce(into: [RemoteFileEntry]()) { entries, entry in
                guard !entries.contains(where: { $0.path == entry.path }) else { return }
                entries.append(entry)
            }
        let totalUnitCount = max(1, uniqueEntries.count)

        for (index, sourceEntry) in uniqueEntries.enumerated() {
            let destinationDirectory = RemoteFilePath.normalize(destinationDirectoryPath)
            let destinationPath = RemoteFilePath.appending(sourceEntry.name, to: destinationDirectory)

            guard destinationPath != sourceEntry.path else { continue }

            if sourceEntry.type == .directory {
                let normalizedSource = RemoteFilePath.normalize(sourceEntry.path)
                if destinationDirectory == normalizedSource || destinationDirectory.hasPrefix(normalizedSource + "/") {
                    throw RemoteFileBrowserError.failed(
                        String(localized: "A folder cannot be moved into itself or one of its descendants.")
                    )
                }
            }

            try await browser.renameItem(
                at: sourceEntry.path,
                to: destinationPath,
                serverId: server.id
            )
            onProgress?(
                RemoteFileBrowserManager.TransferProgress(
                    completedUnitCount: index + 1,
                    totalUnitCount: totalUnitCount,
                    currentItemName: sourceEntry.name
                )
            )
        }
    }

    func transferDroppedRemoteItems(
        _ payloads: [RemoteFileDragPayload],
        to destinationDirectoryPath: String,
        onProgress: (@MainActor (RemoteFileBrowserManager.TransferProgress) -> Void)? = nil
    ) async throws {
        let sourceServerIDs = Set(payloads.map(\.serverId))
        guard sourceServerIDs.count == 1, let sourceServerId = sourceServerIDs.first else {
            throw RemoteFileBrowserError.failed(
                String(localized: "A single drop can only contain items from one remote server.")
            )
        }

        if sourceServerId == server.id {
            try await moveDroppedRemoteItems(
                payloads,
                to: destinationDirectoryPath,
                onProgress: onProgress
            )
            return
        }

        let uniqueEntries = payloads
            .flatMap(\.entries)
            .reduce(into: [RemoteFileEntry]()) { entries, entry in
                guard !entries.contains(where: { $0.path == entry.path }) else { return }
                entries.append(entry)
            }
        try await browser.copyEntries(
            uniqueEntries,
            from: sourceServerId,
            to: destinationDirectoryPath,
            destinationServerId: server.id,
            onProgress: onProgress
        )
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
        guard let destinationPath = newFolderDestinationPath else { return }
        guard !isCreateFolderSubmitting else { return }
        guard !trimmedNewFolderName.isEmpty else {
            resetNewFolderPrompt()
            return
        }
        isCreateFolderSubmitting = true

        performOperation(
            operation: {
                let folderName = try validatedRemoteName(trimmedNewFolderName)
                try await browser.createDirectory(
                    named: folderName,
                    in: destinationPath,
                    serverId: server.id
                )
            },
            onSuccess: { _ in
                resetNewFolderPrompt()
            },
            onFailure: { error in
                isCreateFolderSubmitting = false
                presentOperationError(error)
            }
        )
    }

    func renameEntry() {
        guard let entry = renameTargetEntry, !isRenameSubmitting else { return }
        isRenameSubmitting = true

        performOperation(
            operation: {
                let newName = try validatedRemoteName(trimmedRenameName)
                guard newName != entry.name else {
                    return false
                }

                let destinationPath = RemoteFilePath.appending(
                    newName,
                    to: RemoteFilePath.parent(of: entry.path)
                )
                try await browser.renameItem(
                    at: entry.path,
                    to: destinationPath,
                    serverId: server.id
                )
                return true
            },
            onSuccess: { _ in
                resetRenamePrompt()
            },
            onFailure: { error in
                isRenameSubmitting = false
                presentOperationError(error)
            }
        )
    }

    func moveEntry() {
        guard let entry = moveTargetEntry, !isMoveSubmitting else { return }
        isMoveSubmitting = true

        performOperation(
            operation: {
                let sourceDirectory = RemoteFilePath.parent(of: entry.path)
                let destinationDirectory = try validatedRemoteDirectoryPath(
                    moveDestinationDirectory,
                    relativeTo: sourceDirectory
                )
                let destinationPath = RemoteFilePath.appending(entry.name, to: destinationDirectory)

                guard destinationPath != entry.path else {
                    return false
                }

                try await browser.renameItem(
                    at: entry.path,
                    to: destinationPath,
                    serverId: server.id
                )
                return true
            },
            onSuccess: { _ in
                resetMovePrompt()
            },
            onFailure: { error in
                isMoveSubmitting = false
                presentOperationError(error)
            }
        )
    }

    func deleteEntry() {
        guard let entry = deleteTargetEntry else { return }
        deleteTargetEntry = nil

        deleteEntries([entry])
    }

    func deleteEntries(_ entries: [RemoteFileEntry]) {
        guard !entries.isEmpty else { return }

        performOperation {
            for entry in entries {
                try await browser.deleteItem(
                    at: entry.path,
                    serverId: server.id,
                    type: entry.type
                )
            }
        }
    }

    func requestDelete(_ entries: [RemoteFileEntry]) {
        guard !entries.isEmpty else { return }

        #if os(macOS)
        presentMacOSDeleteConfirmation(for: entries)
        #else
        guard entries.count == 1, let entry = entries.first else { return }
        deleteTargetEntry = entry
        #endif
    }

    func resetNewFolderPrompt() {
        newFolderDestinationPath = nil
        newFolderName = ""
        isCreateFolderSubmitting = false
    }

    func resetRenamePrompt() {
        renameTargetEntry = nil
        renameName = ""
        isRenameSubmitting = false
    }

    func resetMovePrompt() {
        moveTargetEntry = nil
        moveDestinationDirectory = ""
        isMoveSubmitting = false
    }

    func applyPermissions() {
        guard let entry = permissionTargetEntry, !isPermissionSubmitting else { return }
        isPermissionSubmitting = true

        performOperation(
            operation: {
                let requestedPermissions = permissionPreservedBits | permissionDraft.accessBits
                try await browser.setPermissions(entry, permissions: requestedPermissions, serverId: server.id)
            },
            onSuccess: { _ in
                resetPermissionEditor()
            },
            onFailure: { error in
                isPermissionSubmitting = false
                presentOperationError(error)
            }
        )
    }

    func resetPermissionEditor() {
        permissionTargetEntry = nil
        permissionDraft = RemoteFilePermissionDraft(accessBits: 0)
        permissionOriginalAccessBits = 0
        permissionPreservedBits = 0
        isPermissionSubmitting = false
    }

    func validatedRemoteName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "Name cannot be empty."))
        }
        guard trimmed != ".", trimmed != ".." else {
            throw RemoteFileBrowserError.failed(String(localized: "This name is not allowed."))
        }
        guard !trimmed.contains("/") else {
            throw RemoteFileBrowserError.failed(String(localized: "Names cannot contain slashes."))
        }
        return trimmed
    }

    func validatedRemoteDirectoryPath(_ value: String, relativeTo currentPath: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "Destination folder cannot be empty."))
        }
        return RemoteFilePath.normalize(trimmed, relativeTo: currentPath)
    }

    func temporaryDownloadURL(for entry: RemoteFileEntry) throws -> URL {
        let fileManager = FileManager.default
        let downloadDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("VVTermDownloads", isDirectory: true)
        try fileManager.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)

        let uniquePrefix = UUID().uuidString
        let filename = entry.name.isEmpty ? "download" : entry.name
        return downloadDirectory.appendingPathComponent("\(uniquePrefix)-\(filename)")
    }

    func cleanupDownloadExport() {
        if let sourceURL = downloadExportDocument?.sourceURL {
            try? FileManager.default.removeItem(at: sourceURL)
        }
        downloadExportDocument = nil
        downloadExportFilename = ""
    }

    func cleanupShareItem() {
        if let sourceURL = shareItem?.sourceURL {
            try? FileManager.default.removeItem(at: sourceURL)
        }
        shareItem = nil
    }

    func finishSharing(_ item: RemoteFileShareItem) {
        guard shareItem?.id == item.id else { return }
        cleanupShareItem()
    }

    func currentFolderTitle(for path: String) -> String {
        RemoteFilePath.breadcrumbs(for: path).last?.title ?? "/"
    }

    #if os(macOS)
    func presentMacOSUploadPanel(for remotePath: String) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Upload to Remote Folder")
        panel.message = String(localized: "Choose files or folders to upload.")
        panel.prompt = String(localized: "Upload")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        let response = panel.runModal()
        guard response == .OK else { return }

        let urls = panel.urls
        guard !urls.isEmpty else { return }

        performTransfer(
            title: String(localized: "Uploading"),
            initialMessage: String(localized: "Preparing files for upload."),
            successMessage: String(localized: "Upload complete.")
        ) { onProgress in
            try await browser.uploadFiles(
                at: urls,
                to: remotePath,
                serverId: server.id,
                onProgress: onProgress
            )
        }
    }

    func presentMacOSDownloadPanel(for entry: RemoteFileEntry) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Download Remote File")
        panel.message = String(localized: "Choose where to save the downloaded file.")
        panel.nameFieldStringValue = entry.name.isEmpty ? "download" : entry.name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let response = panel.runModal()
        guard response == .OK, let destinationURL = panel.url else { return }

        performTransfer(
            title: String(localized: "Downloading"),
            initialMessage: String(localized: "Downloading remote file."),
            successMessage: String(localized: "Download complete.")
        ) {
            try await browser.downloadFile(
                at: entry.path,
                to: destinationURL,
                serverId: server.id
            )
        }
    }

    func presentMacOSDeleteConfirmation(for entries: [RemoteFileEntry]) {
        let sortedEntries = entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "trash", accessibilityDescription: String(localized: "Delete"))

        if sortedEntries.count == 1, let entry = sortedEntries.first {
            alert.messageText = deleteAlertTitle(for: entry)
            alert.informativeText = deleteAlertMessage(for: entry)
        } else {
            alert.messageText = String(
                format: String(localized: "Delete %lld Items?"),
                Int64(sortedEntries.count)
            )

            let previewNames = sortedEntries.prefix(3).map(\.name).joined(separator: ", ")
            if sortedEntries.count > 3 {
                alert.informativeText = String(
                    format: String(localized: "This will permanently remove %@ and %lld more items from the remote server. This cannot be undone."),
                    previewNames,
                    Int64(sortedEntries.count - 3)
                )
            } else {
                alert.informativeText = String(
                    format: String(localized: "This will permanently remove %@ from the remote server. This cannot be undone."),
                    previewNames
                )
            }
        }

        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        deleteEntries(sortedEntries)
    }
    #endif

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
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
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
