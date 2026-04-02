import AVKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct RemoteFileInspectorView: View {
    enum Chrome {
        case sidebar
        case sheet
    }

    private enum InspectorTab: String, CaseIterable, Identifiable {
        case metadata
        case content

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .metadata:
                return "Metadata"
            case .content:
                return "Preview"
            }
        }
    }

    let selectedEntry: RemoteFileEntry?
    let viewerPayload: RemoteFileViewerPayload?
    let isLoadingViewer: Bool
    let viewerError: RemoteFileBrowserError?
    let directoryError: RemoteFileBrowserError?
    let chrome: Chrome
    let backgroundColor: Color
    let previewBackgroundColor: Color
    let sectionBackgroundColor: Color
    let onLoadPreview: ((RemoteFileEntry) -> Void)?
    let onDownloadPreview: ((RemoteFileEntry) -> Void)?
    let onDownload: ((RemoteFileEntry) -> Void)?
    let onShare: ((RemoteFileEntry) -> Void)?
    let onRename: ((RemoteFileEntry) -> Void)?
    let onMove: ((RemoteFileEntry) -> Void)?
    let onEditPermissions: ((RemoteFileEntry) -> Void)?
    let onDelete: ((RemoteFileEntry) -> Void)?
    let onClose: (() -> Void)?
    let onSaveText: ((RemoteFileEntry, String) async throws -> Void)?

    @State private var selectedTab: InspectorTab = .metadata
    @State private var editableText = ""
    @State private var isEditingText = false
    @State private var isSavingText = false
    @State private var textSaveErrorMessage: String?
    @State private var presentedMediaPreview: PresentedMediaPreview?

    var body: some View {
        Group {
            if chrome == .sidebar {
                sidebarInspectorContent
            } else {
                sheetInspectorContent
            }
        }
        .background(backgroundColor)
        .onChange(of: selectedEntry?.path) { _ in
            selectedTab = .metadata
            isEditingText = false
            isSavingText = false
            textSaveErrorMessage = nil
            editableText = viewerPayload?.textPreview ?? ""
        }
        .onChange(of: viewerPayload?.textPreview) { newValue in
            guard !isEditingText else { return }
            editableText = newValue ?? ""
        }
        .task(id: previewRequestID) {
            guard selectedTab == .content, let selectedEntry else { return }
            guard viewerPayload?.entry.path != selectedEntry.path else { return }
            guard !isLoadingViewer else { return }
            guard viewerError == nil else { return }
            onLoadPreview?(selectedEntry)
        }
        .alert(String(localized: "Unable to Save"), isPresented: textSaveErrorBinding) {
            Button(String(localized: "OK"), role: .cancel) {
                textSaveErrorMessage = nil
            }
        } message: {
            Text(textSaveErrorMessage ?? "")
        }
        .sheet(item: $presentedMediaPreview) { item in
            RemoteFileExpandedMediaPreview(item: item)
        }
    }

    @ViewBuilder
    private var sidebarInspectorContent: some View {
        if let selectedEntry {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: chrome == .sidebar ? 12 : 16) {
                    inspectorHeader(for: selectedEntry)
                    inspectorTabs
                }
                .padding(chrome == .sidebar ? 12 : 16)
                .frame(maxWidth: .infinity, alignment: .leading)

                if selectedTab == .metadata {
                    Form {
                        metadataFormSection(for: selectedEntry)
                    }
                    .formStyle(.grouped)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .scrollContentBackground(.hidden)
                    .background(backgroundColor)
                } else {
                    ScrollView {
                        previewContent(for: selectedEntry)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if chrome == .sidebar, onClose != nil {
                        HStack {
                            Spacer(minLength: 0)
                            closeInspectorButton
                        }
                    }

                    if let directoryError {
                        RemoteFileEmptyState(
                            icon: "exclamationmark.triangle.fill",
                            title: String(localized: "Preview Unavailable"),
                            message: directoryError.errorDescription ?? directoryError.localizedDescription
                        )
                    } else {
                        RemoteFileEmptyState(
                            icon: "doc.text.magnifyingglass",
                            title: String(localized: "Select a File"),
                            message: String(localized: "Choose a file to inspect its metadata.")
                        )
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var sheetInspectorContent: some View {
        VStack(spacing: 0) {
            if selectedEntry != nil {
                inspectorTabs
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }

            Form {
                if let selectedEntry {
                    if selectedTab == .metadata {
                        metadataFormSection(for: selectedEntry)

                        if showsPrimaryActions(for: selectedEntry) {
                            primaryActionsFormSection(for: selectedEntry)
                        }

                        if onDelete != nil {
                            deleteFormSection(for: selectedEntry)
                        }
                    } else {
                        previewFormSection(for: selectedEntry)
                    }
                } else if let directoryError {
                    Section {
                        inspectorStatusMessage(
                            title: String(localized: "Preview Unavailable"),
                            message: directoryError.errorDescription ?? directoryError.localizedDescription,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    }
                } else {
                    Section {
                        inspectorStatusMessage(
                            title: String(localized: "Select a File"),
                            message: String(localized: "Choose a file to inspect its metadata."),
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(backgroundColor)
        }
        .background(backgroundColor)
    }

    private var inspectorTabs: some View {
        HStack(spacing: 4) {
            ForEach(InspectorTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .frame(height: 36)
                        .background(
                            selectedTab == tab ? Color.primary.opacity(0.18) : Color.clear,
                            in: Capsule(style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
        )
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func previewContent(for selectedEntry: RemoteFileEntry) -> some View {
        if let viewerPayload, viewerPayload.entry.path == selectedEntry.path {
            loadedSidebarPreviewContent(viewerPayload, selectedEntry: selectedEntry)
        } else if isLoadingViewer {
            RemoteFileEmptyState(
                icon: "doc.text.magnifyingglass",
                title: String(localized: "Loading Preview"),
                message: String(localized: "Fetching the remote file contents.")
            )
        } else if let viewerError {
            VStack(alignment: .leading, spacing: 12) {
                RemoteFileEmptyState(
                    icon: "exclamationmark.triangle.fill",
                    title: String(localized: "Preview Unavailable"),
                    message: viewerError.errorDescription ?? viewerError.localizedDescription
                )

                if let onLoadPreview {
                    Button(String(localized: "Retry Preview")) {
                        onLoadPreview(selectedEntry)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        } else {
            RemoteFileEmptyState(
                icon: "doc.text.magnifyingglass",
                title: String(localized: "Loading Preview"),
                message: String(localized: "Fetching the remote file contents.")
            )
        }
    }

    @ViewBuilder
    private func loadedSidebarPreviewContent(
        _ payload: RemoteFileViewerPayload,
        selectedEntry: RemoteFileEntry
    ) -> some View {
        switch payload.previewKind {
        case .text:
            textPreviewSection(
                payload,
                selectedEntry: selectedEntry,
                useSectionBackground: true
            )
        case .image, .video:
            mediaPreviewSection(payload)
        case .unavailable:
            if payload.requiresExplicitDownload {
                previewDownloadPrompt(payload)
            } else {
                previewUnavailableState(payload)
            }
        }
    }

    private func textPreviewSection(
        _ payload: RemoteFileViewerPayload,
        selectedEntry: RemoteFileEntry,
        useSectionBackground: Bool,
        showsHeader: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                Text(String(localized: "Preview"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if isEditingText {
                TextEditor(text: $editableText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(previewContainerBackground(useSectionBackground: useSectionBackground))
            } else {
                ScrollView(.vertical) {
                    Text(payload.textPreview ?? "")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
                .padding(12)
                .background(previewContainerBackground(useSectionBackground: useSectionBackground))
            }

            if payload.canEditText, onSaveText != nil {
                textEditingControls(for: selectedEntry, originalText: payload.textPreview ?? "")
            }

            if payload.isTruncated {
                Text(String(localized: "Preview output was truncated to avoid loading large remote files."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func textEditingControls(for entry: RemoteFileEntry, originalText: String) -> some View {
        HStack(spacing: 10) {
            if isEditingText {
                Button(String(localized: "Cancel")) {
                    isEditingText = false
                    editableText = originalText
                }
                .buttonStyle(.bordered)

                Button(String(localized: "Save")) {
                    Task {
                        await saveEditedText(for: entry)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSavingText || editableText == originalText)
            } else {
                Button(String(localized: "Edit Text")) {
                    editableText = originalText
                    isEditingText = true
                }
                .buttonStyle(.bordered)
            }

            if isSavingText {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func mediaPreviewSection(
        _ payload: RemoteFileViewerPayload,
        showsHeader: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                Text(String(localized: "Preview"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let previewFileURL = payload.previewFileURL {
                switch payload.previewKind {
                case .image:
                    Button {
                        presentMediaPreview(payload)
                    } label: {
                        RemoteFileImagePreview(url: previewFileURL, backgroundColor: previewBackground)
                    }
                    .buttonStyle(.plain)
                case .video:
                    RemoteFileVideoPreview(url: previewFileURL, backgroundColor: previewBackground)
                case .text, .unavailable:
                    EmptyView()
                }

                Button {
                    presentMediaPreview(payload)
                } label: {
                    Label(String(localized: "Open Full Preview"), systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.bordered)
            } else {
                if payload.requiresExplicitDownload {
                    previewDownloadPrompt(payload)
                } else {
                    previewUnavailableState(payload)
                }
            }
        }
    }

    @ViewBuilder
    private func previewDownloadPrompt(_ payload: RemoteFileViewerPayload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RemoteFileEmptyState(
                icon: "arrow.down.circle",
                title: String(localized: "Download Preview"),
                message: payload.unavailableMessage
                    ?? String(localized: "Download the remote file to generate an inline preview.")
            )

            if let onDownloadPreview {
                Button {
                    onDownloadPreview(payload.entry)
                } label: {
                    let sizeLabel = previewSizeLabel(for: payload)
                    if let sizeLabel {
                        Label(
                            String(
                                format: String(localized: "Download Preview (%@)"),
                                sizeLabel
                            ),
                            systemImage: "arrow.down.circle"
                        )
                    } else {
                        Label(String(localized: "Download Preview"), systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func previewUnavailableState(_ payload: RemoteFileViewerPayload) -> some View {
        VStack {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 12) {
                RemoteFileEmptyState(
                    icon: "doc.text.magnifyingglass",
                    title: String(localized: "Preview Unavailable"),
                    message: unavailablePreviewMessage(for: payload)
                )

                unavailablePreviewAction(payload)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    @ViewBuilder
    private func unavailablePreviewAction(_ payload: RemoteFileViewerPayload) -> some View {
        #if os(macOS)
        if let previewFileURL = payload.previewFileURL {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([previewFileURL])
            } label: {
                Label(String(localized: "Reveal in Finder"), systemImage: "finder")
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        } else if canShare(payload.entry) {
            Button {
                onShare?(payload.entry)
            } label: {
                Label(String(localized: "Open in Another App"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        #else
        if canDownload(payload.entry) {
            Button {
                onDownload?(payload.entry)
            } label: {
                Label(String(localized: "Save to Files"), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        #endif
    }

    private func unavailablePreviewMessage(for payload: RemoteFileViewerPayload) -> String {
        #if os(macOS)
        if payload.previewKind == .video, payload.previewFileURL != nil {
            return String(
                localized: "Inline video preview is unreliable for this downloaded file on macOS. Reveal it in Finder and open it with another app such as VLC or IINA."
            )
        }
        #endif

        if let message = payload.unavailableMessage {
            if message == String(localized: "This file downloaded successfully, but macOS could not open it for inline preview.") {
                return String(
                    localized: "This file downloaded successfully, but macOS could not decode it for inline preview. Reveal it in Finder and open it with another app such as VLC or IINA."
                )
            }
            return message
        }

        return String(localized: "Inline preview is unavailable for this file.")
    }

    private func previewContainerBackground(useSectionBackground: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(useSectionBackground ? previewBackground : Color.clear)
    }

    private func metadataSection(for entry: RemoteFileEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Information"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            VStack(spacing: 0) {
                metadataRow(String(localized: "Name"), value: entry.name)
                metadataDivider
                metadataRow(String(localized: "Kind"), value: kindLabel(for: entry))
                metadataDivider
                metadataRow(String(localized: "Location"), value: entry.path)
                metadataDivider
                metadataRow(String(localized: "Size"), value: sizeLabel(for: entry))
                metadataDivider
                metadataRow(String(localized: "Modified"), value: modifiedLabel(for: entry))

                if let permissions = entry.formattedPermissions {
                    metadataDivider
                    metadataRow(String(localized: "Permissions"), value: permissions)
                }

                if let target = entry.symlinkTarget {
                    metadataDivider
                    metadataRow(String(localized: "Symlink"), value: target)
                }
            }

            if showsPrimaryActions(for: entry) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "Actions"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 10) {
                        if canDownload(entry) {
                            inspectorActionButton(
                                title: String(localized: "Download…"),
                                systemImage: "arrow.down.circle"
                            ) {
                                onDownload?(entry)
                            }
                        }

                        if onRename != nil {
                            inspectorActionButton(
                                title: String(localized: "Rename…"),
                                systemImage: "pencil"
                            ) {
                                onRename?(entry)
                            }
                        }

                        if onMove != nil {
                            inspectorActionButton(
                                title: String(localized: "Move…"),
                                systemImage: "arrow.right.circle"
                            ) {
                                onMove?(entry)
                            }
                        }

                        if canEditPermissions(entry) {
                            inspectorActionButton(
                                title: String(localized: "Permissions…"),
                                systemImage: "lock.shield"
                            ) {
                                onEditPermissions?(entry)
                            }
                        }
                    }
                }
            }

            if onDelete != nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "Remove"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    inspectorActionButton(
                        title: String(localized: "Delete"),
                        systemImage: "trash",
                        tint: .red
                    ) {
                        onDelete?(entry)
                    }
                }
            }
        }
    }

    private func metadataFormSection(for entry: RemoteFileEntry) -> some View {
        Section(String(localized: "Information")) {
            metadataFormRow(String(localized: "Name"), value: entry.name)
            metadataFormRow(String(localized: "Kind"), value: kindLabel(for: entry))
            metadataFormMultilineRow(String(localized: "Location"), value: entry.path)
            metadataFormRow(String(localized: "Size"), value: sizeLabel(for: entry))
            metadataFormRow(String(localized: "Modified"), value: modifiedLabel(for: entry))

            if let permissions = entry.formattedPermissions {
                metadataFormRow(String(localized: "Permissions"), value: permissions)
            }

            if let target = entry.symlinkTarget {
                metadataFormMultilineRow(String(localized: "Symlink"), value: target)
            }
        }
    }

    private func primaryActionsFormSection(for entry: RemoteFileEntry) -> some View {
        Section(String(localized: "Actions")) {
            if canDownload(entry) {
                Button {
                    onDownload?(entry)
                } label: {
                    Label(String(localized: "Download"), systemImage: "arrow.down.circle")
                }
            }

            if canShare(entry) {
                Button {
                    onShare?(entry)
                } label: {
                    Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
                }
            }

            if onRename != nil {
                Button {
                    onRename?(entry)
                } label: {
                    Label(String(localized: "Rename"), systemImage: "pencil")
                }
            }

            if onMove != nil {
                Button {
                    onMove?(entry)
                } label: {
                    Label(String(localized: "Move"), systemImage: "arrow.right.circle")
                }
            }

            if canEditPermissions(entry) {
                Button {
                    onEditPermissions?(entry)
                } label: {
                    Label(String(localized: "Permissions"), systemImage: "lock.shield")
                }
            }
        }
    }

    private func deleteFormSection(for entry: RemoteFileEntry) -> some View {
        Section {
            Button(role: .destructive) {
                onDelete?(entry)
            } label: {
                Label {
                    Text(String(localized: "Delete"))
                } icon: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func inspectorHeader(for entry: RemoteFileEntry) -> some View {
        HStack(alignment: .top, spacing: chrome == .sidebar ? 12 : 14) {
            RoundedRectangle(cornerRadius: inspectorHeaderIconCornerRadius, style: .continuous)
                .fill(sectionBackground)
                .frame(width: inspectorHeaderIconSize, height: inspectorHeaderIconSize)
                .overlay {
                    Image(systemName: entry.iconName)
                        .font(.system(size: inspectorHeaderSymbolSize, weight: .medium))
                        .foregroundStyle(inspectorIconTint(for: entry))
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(inspectorHeaderTitleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(inspectorSubtitle(for: entry))
                    .font(inspectorHeaderSubtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if chrome == .sidebar {
                HStack(spacing: 6) {
                    Menu {
                        sidebarInspectorActionMenu(for: entry)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(Text("File Actions"))

                    if onClose != nil {
                        closeInspectorButton
                    }
                }
            }
        }
    }

    private var closeInspectorButton: some View {
        Button {
            onClose?()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .help(Text("Close Preview"))
    }

    @ViewBuilder
    private func sidebarInspectorActionMenu(for entry: RemoteFileEntry) -> some View {
        if canDownload(entry) {
            Button {
                onDownload?(entry)
            } label: {
                Label(String(localized: "Download…"), systemImage: "arrow.down.circle")
            }
        }

        if canShare(entry) {
            Button {
                onShare?(entry)
            } label: {
                Label(String(localized: "Share…"), systemImage: "square.and.arrow.up")
            }
        }

        if canDownload(entry) || canShare(entry) {
            Divider()
        }

        if canEditPermissions(entry) {
            Button {
                onEditPermissions?(entry)
            } label: {
                Label(String(localized: "Permissions…"), systemImage: "lock.shield")
            }
        }

        if onRename != nil {
            Button {
                onRename?(entry)
            } label: {
                Label(String(localized: "Rename…"), systemImage: "pencil")
            }
        }

        if onMove != nil {
            Button {
                onMove?(entry)
            } label: {
                Label(String(localized: "Move…"), systemImage: "arrow.right.circle")
            }
        }

        Divider()

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

        if onDelete != nil {
            Divider()

            Button(role: .destructive) {
                onDelete?(entry)
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
    }

    private func inspectorSubtitle(for entry: RemoteFileEntry) -> String {
        let kind = kindLabel(for: entry)
        let size = sizeLabel(for: entry)
        guard size != "—" else { return kind }
        return "\(kind) - \(size)"
    }

    private func metadataFormRow(_ key: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .textSelection(.enabled)
        } label: {
            Text(key)
        }
    }

    private func metadataFormMultilineRow(_ key: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(key)
                .foregroundStyle(.primary)

            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func previewFormSection(for selectedEntry: RemoteFileEntry) -> some View {
        Section {
            if let viewerPayload, viewerPayload.entry.path == selectedEntry.path {
                switch viewerPayload.previewKind {
                case .text:
                    textPreviewSection(
                        viewerPayload,
                        selectedEntry: selectedEntry,
                        useSectionBackground: false,
                        showsHeader: false
                    )
                case .image, .video:
                    mediaPreviewSection(viewerPayload, showsHeader: false)
                case .unavailable:
                    if viewerPayload.requiresExplicitDownload {
                        previewDownloadPrompt(viewerPayload)
                    } else {
                        inspectorStatusMessage(
                            title: String(localized: "Preview Unavailable"),
                            message: viewerPayload.unavailableMessage
                                ?? String(localized: "Inline preview is unavailable for this file."),
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                }
            } else if isLoadingViewer {
                inspectorLoadingMessage(
                    title: String(localized: "Loading Preview"),
                    message: String(localized: "Fetching the remote file contents.")
                )
            } else if let viewerError {
                inspectorStatusMessage(
                    title: String(localized: "Preview Unavailable"),
                    message: viewerError.errorDescription ?? viewerError.localizedDescription,
                    systemImage: "exclamationmark.triangle.fill"
                )

                if let onLoadPreview {
                    Button(String(localized: "Retry Preview")) {
                        onLoadPreview(selectedEntry)
                    }
                }
            } else {
                inspectorLoadingMessage(
                    title: String(localized: "Loading Preview"),
                    message: String(localized: "Fetching the remote file contents.")
                )
            }
        } header: {
            Text(String(localized: "Preview"))
        }
    }

    private var textSaveErrorBinding: Binding<Bool> {
        Binding(
            get: { textSaveErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    textSaveErrorMessage = nil
                }
            }
        )
    }

    private func saveEditedText(for entry: RemoteFileEntry) async {
        guard let onSaveText else { return }

        isSavingText = true
        do {
            try await onSaveText(entry, editableText)
            isEditingText = false
            textSaveErrorMessage = nil
        } catch {
            textSaveErrorMessage = error.localizedDescription
        }
        isSavingText = false
    }

    private func inspectorStatusMessage(title: String, message: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func inspectorLoadingMessage(title: String, message: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func inspectorIconTint(for entry: RemoteFileEntry) -> Color {
        switch entry.type {
        case .directory:
            return .accentColor
        case .symlink:
            return .secondary
        case .other:
            return .secondary
        case .file:
            return .primary
        }
    }

    private func metadataRow(_ key: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(key)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: metadataLabelWidth, alignment: .leading)

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
    }

    private func inspectorActionButton(
        title: String,
        systemImage: String,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .frame(width: 18)

                Text(title)
                    .font(.body.weight(.semibold))

                Spacer(minLength: 12)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(sectionBackground)
            )
        }
        .buttonStyle(.plain)
    }

    private var metadataDivider: some View {
        Divider()
    }

    private func canDownload(_ entry: RemoteFileEntry) -> Bool {
        entry.type != .directory && onDownload != nil
    }

    private var inspectorHeaderIconSize: CGFloat {
        chrome == .sidebar ? 36 : 56
    }

    private var inspectorHeaderIconCornerRadius: CGFloat {
        chrome == .sidebar ? 9 : 14
    }

    private var inspectorHeaderSymbolSize: CGFloat {
        chrome == .sidebar ? 17 : 26
    }

    private var inspectorHeaderTitleFont: Font {
        chrome == .sidebar ? .headline.weight(.semibold) : .title2.weight(.semibold)
    }

    private var inspectorHeaderSubtitleFont: Font {
        chrome == .sidebar ? .subheadline : .title3
    }

    private func canShare(_ entry: RemoteFileEntry) -> Bool {
        entry.type != .directory && onShare != nil
    }

    private func canEditPermissions(_ entry: RemoteFileEntry) -> Bool {
        guard onEditPermissions != nil, entry.permissions != nil else { return false }
        return entry.type != .symlink
    }

    private func showsPrimaryActions(for entry: RemoteFileEntry) -> Bool {
        canDownload(entry) || canShare(entry) || onRename != nil || onMove != nil || canEditPermissions(entry)
    }

    private func modifiedLabel(for entry: RemoteFileEntry) -> String {
        guard let modifiedAt = entry.modifiedAt else { return "—" }
        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func sizeLabel(for entry: RemoteFileEntry) -> String {
        guard entry.type != .directory, let size = entry.size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func kindLabel(for entry: RemoteFileEntry) -> String {
        switch entry.type {
        case .directory:
            return String(localized: "Folder")
        case .symlink:
            return String(localized: "Symlink")
        case .other:
            return String(localized: "Document")
        case .file:
            return entry.metadataTypeLabel == RemoteFileType.file.displayName
                ? String(localized: "Document")
                : entry.metadataTypeLabel
        }
    }

    private var previewBackground: Color {
        previewBackgroundColor
    }

    private var sectionBackground: Color {
        sectionBackgroundColor
    }

    private var metadataLabelWidth: CGFloat {
        chrome == .sidebar ? 108 : 120
    }

    private var previewRequestID: String {
        guard selectedTab == .content, let selectedEntry else { return "metadata" }
        return selectedEntry.path
    }

    private func previewSizeLabel(for payload: RemoteFileViewerPayload) -> String? {
        guard let byteCount = payload.previewByteCount else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    private func presentMediaPreview(_ payload: RemoteFileViewerPayload) {
        guard let url = payload.previewFileURL else { return }
        presentedMediaPreview = PresentedMediaPreview(
            title: payload.entry.name,
            kind: payload.previewKind,
            url: url
        )
    }
}

private struct PresentedMediaPreview: Identifiable {
    let title: String
    let kind: RemoteFilePreviewKind
    let url: URL

    var id: String { url.absoluteString }
}

private struct RemoteFileImagePreview: View {
    let url: URL
    let backgroundColor: Color

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 360)
                    .padding(12)
                    .background(previewBackground)
            } else {
                RemoteFileEmptyState(
                    icon: "photo",
                    title: String(localized: "Preview Unavailable"),
                    message: String(localized: "The image data could not be rendered.")
                )
            }
        }
    }

    #if os(macOS)
    private var image: Image? {
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: nsImage)
    }
    #else
    private var image: Image? {
        guard let uiImage = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: uiImage)
    }
    #endif

    private var previewBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(backgroundColor)
    }
}

private struct RemoteFileVideoPreview: View {
    let url: URL
    let backgroundColor: Color

    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor)
            )
        .task(id: url) {
            player?.pause()
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
        }
    }
}

private struct RemoteFileExpandedMediaPreview: View {
    let item: PresentedMediaPreview

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        #if os(iOS)
        NavigationStack {
            mediaContent
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) {
                            dismiss()
                        }
                    }
                }
        }
        #else
        VStack(spacing: 0) {
            HStack {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button(String(localized: "Close")) {
                    dismiss()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            mediaContent
        }
        .frame(minWidth: 700, minHeight: 520)
        #endif
    }

    @ViewBuilder
    private var mediaContent: some View {
        ZStack {
            Color.black.opacity(0.96)
                .ignoresSafeArea()

            switch item.kind {
            case .image:
                imageContent
            case .video:
                videoContent
            case .text, .unavailable:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        #if os(macOS)
        if let image = NSImage(contentsOf: item.url) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            }
        } else {
            RemoteFileEmptyState(
                icon: "photo",
                title: String(localized: "Preview Unavailable"),
                message: String(localized: "The image data could not be rendered.")
            )
        }
        #else
        if let image = UIImage(contentsOfFile: item.url.path) {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            }
        } else {
            RemoteFileEmptyState(
                icon: "photo",
                title: String(localized: "Preview Unavailable"),
                message: String(localized: "The image data could not be rendered.")
            )
        }
        #endif
    }

    private var videoContent: some View {
        VideoPlayer(player: player)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.url) {
            player?.pause()
            player = AVPlayer(url: item.url)
        }
        .onDisappear {
            player?.pause()
        }
    }
}

struct RemoteFileRenameSheet: View {
    let entry: RemoteFileEntry
    @Binding var proposedName: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onRename: () -> Void

    var body: some View {
        #if os(iOS)
        NavigationStack {
            renameContent
                .navigationTitle(String(localized: "Rename"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) {
                            onCancel()
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Rename")) {
                            onRename()
                        }
                        .disabled(trimmedProposedName.isEmpty || isSubmitting)
                    }
                }
        }
        #else
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "Rename"))
                .font(.title2.weight(.semibold))

            renameContent

            HStack {
                Spacer()

                Button(String(localized: "Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "Rename")) {
                    onRename()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedProposedName.isEmpty || isSubmitting)
            }
        }
        .padding(20)
        #endif
    }

    private var renameContent: some View {
        Form {
            Section(String(localized: "Item")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.name)
                        .font(.headline)

                    Text(entry.path)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }

            Section(String(localized: "New Name")) {
                TextField(String(localized: "Name"), text: $proposedName)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }

            if isSubmitting {
                Section {
                    ProgressView(String(localized: "Renaming…"))
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        #endif
    }

    private var trimmedProposedName: String {
        proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RemoteFileCreateFolderSheet: View {
    let destinationPath: String
    @Binding var folderName: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onCreate: () -> Void

    var body: some View {
        #if os(iOS)
        NavigationStack {
            createFolderContent
                .navigationTitle(String(localized: "New Folder"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) {
                            onCancel()
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Create")) {
                            onCreate()
                        }
                        .disabled(trimmedFolderName.isEmpty || isSubmitting)
                    }
                }
        }
        #else
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "New Folder"))
                .font(.title2.weight(.semibold))

            createFolderContent

            HStack {
                Spacer()

                Button(String(localized: "Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "Create")) {
                    onCreate()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedFolderName.isEmpty || isSubmitting)
            }
        }
        .padding(20)
        #endif
    }

    private var createFolderContent: some View {
        Form {
            Section(String(localized: "Destination")) {
                Text(destinationPath)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .padding(.vertical, 4)
            }

            Section(String(localized: "Folder Name")) {
                TextField(String(localized: "Name"), text: $folderName)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }

            if isSubmitting {
                Section {
                    ProgressView(String(localized: "Creating…"))
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        #endif
    }

    private var trimmedFolderName: String {
        folderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RemoteFileMoveSheet: View {
    let entry: RemoteFileEntry
    @Binding var destinationDirectory: String
    let onLoadDirectories: (String) async throws -> [RemoteFileEntry]
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onMove: () -> Void

    @State private var currentDirectory: String
    @State private var directories: [RemoteFileEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(
        entry: RemoteFileEntry,
        destinationDirectory: Binding<String>,
        onLoadDirectories: @escaping (String) async throws -> [RemoteFileEntry],
        isSubmitting: Bool,
        onCancel: @escaping () -> Void,
        onMove: @escaping () -> Void
    ) {
        self.entry = entry
        _destinationDirectory = destinationDirectory
        self.onLoadDirectories = onLoadDirectories
        self.isSubmitting = isSubmitting
        self.onCancel = onCancel
        self.onMove = onMove
        _currentDirectory = State(initialValue: destinationDirectory.wrappedValue)
    }

    var body: some View {
        Group {
            #if os(iOS)
            NavigationStack {
                moveContent
                    .navigationTitle(String(localized: "Move"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "Cancel")) {
                                onCancel()
                            }
                        }

                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Move")) {
                                onMove()
                            }
                            .disabled(destinationDirectory.isEmpty || isSubmitting)
                        }
                    }
            }
            #else
            VStack(alignment: .leading, spacing: 18) {
                Text(String(localized: "Move"))
                    .font(.title2.weight(.semibold))

                moveContent

                HStack {
                    Spacer()

                    Button(String(localized: "Cancel")) {
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(String(localized: "Move")) {
                        onMove()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(destinationDirectory.isEmpty || isSubmitting)
                }
            }
            .padding(20)
            #endif
        }
        .task(id: currentDirectory) {
            await loadDirectories()
        }
    }

    private var moveContent: some View {
        Form {
            Section(String(localized: "Item")) {
                HStack(spacing: 12) {
                    Image(systemName: entry.iconName)
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.headline)
                            .lineLimit(2)

                        Text(entry.path)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(String(localized: "Selected Folder")) {
                selectedDestinationRow
            }

            Section(String(localized: "Choose Folder")) {
                if currentDirectory != "/" {
                    Button {
                        navigate(to: RemoteFilePath.parent(of: currentDirectory))
                    } label: {
                        pickerRow(
                            title: String(localized: "Up"),
                            systemImage: "arrow.up",
                            iconColor: .accentColor
                        )
                    }
                }

                Button {
                    navigate(to: "/")
                } label: {
                    pickerRow(
                        title: String(localized: "Root"),
                        systemImage: "externaldrive",
                        iconColor: .accentColor
                    )
                }

                if isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(String(localized: "Loading folders…"))
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button(String(localized: "Retry")) {
                            Task { await loadDirectories() }
                        }
                    }
                } else if directories.isEmpty {
                    Text(String(localized: "No subfolders in this location."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(directories.enumerated()), id: \.element.id) { _, directory in
                        Button {
                            navigate(to: directory.path)
                        } label: {
                            pickerRow(
                                title: directory.name,
                                systemImage: "folder",
                                iconColor: .accentColor,
                                showsCheckmark: currentDirectory == directory.path
                            )
                        }
                    }
                }
            }

            if isSubmitting {
                Section {
                    ProgressView(String(localized: "Moving…"))
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        #endif
    }

    private var selectedDestinationRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.badge.checkmark")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(folderDisplayName(for: destinationDirectory))
                    .font(.headline)
                    .lineLimit(1)

                Text(destinationDirectory)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func pickerRow(
        title: String,
        systemImage: String,
        iconColor: Color,
        showsCheckmark: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(iconColor)

            Text(title)
                .foregroundStyle(.primary)

            Spacer()

            if showsCheckmark {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    @MainActor
    private func loadDirectories() async {
        isLoading = true
        errorMessage = nil
        do {
            directories = try await onLoadDirectories(currentDirectory)
        } catch {
            directories = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func navigate(to path: String) {
        let normalizedPath = RemoteFilePath.normalize(path)
        currentDirectory = normalizedPath
        destinationDirectory = normalizedPath
    }

    private func folderDisplayName(for path: String) -> String {
        let normalizedPath = RemoteFilePath.normalize(path)
        guard normalizedPath != "/" else { return String(localized: "Root") }
        return URL(fileURLWithPath: normalizedPath).lastPathComponent
    }
}

struct RemoteFileDeleteConfirmationSheet: View {
    let entry: RemoteFileEntry
    let message: String
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .navigationTitle(String(localized: "Delete"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) {
                            onCancel()
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Delete"), role: .destructive) {
                            onDelete()
                        }
                    }
                }
        }
        #else
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "Delete"))
                .font(.title2.weight(.semibold))

            content

            HStack {
                Spacer()

                Button(String(localized: "Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "Delete"), role: .destructive) {
                    onDelete()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        #endif
    }

    private var content: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "trash.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name)
                            .font(.headline)

                        Text(entry.path)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        #endif
    }
}

struct RemoteFilePermissionEditorSheet: View {
    let entry: RemoteFileEntry
    @Binding var draft: RemoteFilePermissionDraft
    let originalAccessBits: UInt32
    let preservedBits: UInt32
    let errorMessage: String?
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onApply: () -> Void

    private var permissionsChanged: Bool {
        draft.accessBits != originalAccessBits
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(String(localized: "Permissions"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) {
                            onCancel()
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Apply")) {
                            onApply()
                        }
                        .disabled(!permissionsChanged || isSubmitting)
                    }
                }
        }
        #else
        VStack(spacing: 0) {
            content

            Divider()

            HStack {
                Button(String(localized: "Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(String(localized: "Apply")) {
                    onApply()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!permissionsChanged || isSubmitting)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                summaryCard

                ForEach(RemoteFilePermissionAudience.allCases) { audience in
                    permissionGroup(for: audience)
                }

                if let errorMessage, !errorMessage.isEmpty {
                    inlineErrorMessage(errorMessage)
                }

                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if isSubmitting {
                ZStack {
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()

                    ProgressView(String(localized: "Applying Permissions"))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(entry.name, systemImage: entry.iconName)
                .font(.headline)

            Text(entry.path)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Access Summary"))
                .font(.subheadline.weight(.semibold))

            ForEach(RemoteFilePermissionAudience.allCases) { audience in
                HStack(alignment: .top, spacing: 10) {
                    Text(audienceTitle(audience))
                        .font(.callout.weight(.medium))
                        .frame(width: 86, alignment: .leading)

                    Text(accessSummary(for: audience))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Text("Mode \(summaryModeString)")
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.18))
        )
    }

    private func permissionGroup(for audience: RemoteFilePermissionAudience) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(audienceTitle(audience))
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(RemoteFilePermissionCapability.allCases) { capability in
                    Toggle(isOn: permissionBinding(for: capability, audience: audience)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(capabilityTitle(capability))
                                .font(.body.weight(.medium))

                            Text(capabilityDescription(capability))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                    if capability != .execute {
                        Divider()
                            .padding(.leading, 14)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary.opacity(0.14))
            )
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if preservedBits != 0 {
                Text(String(localized: "Special permission bits already on this item will be preserved."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text(footerDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func inlineErrorMessage(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.orange.opacity(0.12))
        )
    }

    private func permissionBinding(
        for capability: RemoteFilePermissionCapability,
        audience: RemoteFilePermissionAudience
    ) -> Binding<Bool> {
        Binding(
            get: {
                draft.isEnabled(capability, for: audience)
            },
            set: { isEnabled in
                draft.set(isEnabled, capability: capability, for: audience)
            }
        )
    }

    private func audienceTitle(_ audience: RemoteFilePermissionAudience) -> String {
        switch audience {
        case .owner:
            return String(localized: "Owner")
        case .group:
            return String(localized: "Group")
        case .everyone:
            return String(localized: "Everyone")
        }
    }

    private func capabilityTitle(_ capability: RemoteFilePermissionCapability) -> String {
        switch capability {
        case .read:
            return String(localized: "Read")
        case .write:
            return String(localized: "Write")
        case .execute:
            return entry.type == .directory
                ? String(localized: "Open Folder")
                : String(localized: "Run")
        }
    }

    private func capabilityDescription(_ capability: RemoteFilePermissionCapability) -> String {
        switch (entry.type, capability) {
        case (.directory, .read):
            return String(localized: "See the names of items inside this folder.")
        case (.directory, .write):
            return String(localized: "Create, rename, or remove items inside this folder.")
        case (.directory, .execute):
            return String(localized: "Open this folder and access items inside it.")
        case (_, .read):
            return String(localized: "Open the file and read its contents.")
        case (_, .write):
            return String(localized: "Change or replace the file contents.")
        case (_, .execute):
            return String(localized: "Run this file as a program or script.")
        }
    }

    private func accessSummary(for audience: RemoteFilePermissionAudience) -> String {
        let granted = RemoteFilePermissionCapability.allCases.compactMap { capability -> String? in
            guard draft.isEnabled(capability, for: audience) else { return nil }
            return capabilityTitle(capability)
        }

        if granted.isEmpty {
            return String(localized: "No access")
        }

        return granted.joined(separator: ", ")
    }

    private var summaryModeString: String {
        let octal = String((preservedBits | draft.accessBits) & 0o7777, radix: 8)
        let padded = String(repeating: "0", count: max(0, 4 - octal.count)) + octal
        return "\(padded) (\(draft.symbolicSummary))"
    }

    private var footerDescription: String {
        if entry.type == .directory {
            return String(localized: "Folder permissions control who can view, change, and enter this folder.")
        }

        return String(localized: "File permissions control who can open, change, or run this file.")
    }
}

struct RemoteFileEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(24)
    }
}

struct RemoteFileLoadingState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(24)
    }
}

struct RemoteFileMessageRow: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

struct RemoteFileDropOverlay: View {
    var body: some View {
        #if os(macOS)
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.accentColor.opacity(0.06))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
            }
            .overlay {
                VStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.down.on.square.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.accentColor)

                    VStack(spacing: 4) {
                        Text(String(localized: "Drop Items Here"))
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text(String(localized: "Upload local files, move items on this server, or copy items from another server."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                .padding(40)
            }
        #else
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(0.8),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 8])
                    )
            }
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.accentColor)

                    Text(String(localized: "Drop to Transfer"))
                        .font(.headline)

                    Text(String(localized: "Local files upload here. Remote items move here on the same server or copy here from another server."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
            }
        #endif
    }
}

struct RemoteFileTransferStatusView: View {
    let status: RemoteFileBrowserView.TransferStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Group {
                    if status.phase == .succeeded {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: 18, height: 18)

                Text(status.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)
            }

            Text(status.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if status.phase == .succeeded, let fileName = status.fileName, !fileName.isEmpty {
                Text(fileName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if status.phase == .succeeded, let filePath = status.filePath, !filePath.isEmpty {
                Text(filePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            if let completedUnitCount = status.completedUnitCount,
               let totalUnitCount = status.totalUnitCount,
               totalUnitCount > 0 {
                ProgressView(value: Double(completedUnitCount), total: Double(totalUnitCount))
                    .tint(status.phase == .succeeded ? .green : .accentColor)

                Text(
                    String(
                        format: String(localized: "%lld of %lld items"),
                        Int64(completedUnitCount),
                        Int64(totalUnitCount)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            #if os(macOS)
            if status.phase == .succeeded, let fileURL = status.fileURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Label(String(localized: "Show in Finder"), systemImage: "finder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            #endif
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 10)
    }
}
