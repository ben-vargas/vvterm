import SwiftUI

#if os(iOS)
import UIKit

extension RemoteFileBrowserScreen {
    @ViewBuilder
    func iOSContent(_ snapshot: Snapshot) -> some View {
        let displayedEntries = iOSDisplayedEntries(snapshot)
        let emptyState = iOSEmptyStateContent(snapshot, displayedEntries: displayedEntries)

        ZStack {
            if emptyState == nil {
                List {
                    ForEach(displayedEntries) { entry in
                        Button {
                            handleIOSEntryTap(entry)
                        } label: {
                            RemoteFileIOSRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .onDrag {
                            dragItemProvider(for: entry)
                        }
                        .onDrop(of: remoteRowDropTypeIdentifiers, isTargeted: nil) { providers in
                            handleFolderDrop(providers, to: entry)
                        }
                        .contextMenu {
                            entryActionMenu(entry)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }

            if let emptyState {
                Group {
                    if emptyState.icon == "spinner" {
                        RemoteFileLoadingState(
                            title: emptyState.title,
                            message: emptyState.message
                        )
                    } else {
                        RemoteFileEmptyState(
                            icon: emptyState.icon,
                            title: emptyState.title,
                            message: emptyState.message
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 24)
            }
        }
        .background(Color.clear)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            iOSBottomPanel(snapshot)
        }
        .navigationDestination(isPresented: iOSPreviewBinding) {
            RemoteFileInspectorView(
                selectedEntry: snapshot.selectedEntry,
                viewerPayload: snapshot.viewerPayload,
                isLoadingViewer: snapshot.isLoadingViewer,
                viewerError: snapshot.viewerError,
                directoryError: snapshot.directoryError,
                chrome: .sheet,
                backgroundColor: Color(UIColor.systemGroupedBackground),
                previewBackgroundColor: Color(UIColor.secondarySystemGroupedBackground),
                sectionBackgroundColor: Color(UIColor.secondarySystemGroupedBackground),
                onLoadPreview: { entry in
                    Task { await browser.loadPreview(for: entry, serverId: server.id) }
                },
                onDownloadPreview: { entry in
                    Task {
                        await browser.loadPreview(for: entry, serverId: server.id, allowLargeDownloads: true)
                    }
                },
                onDownload: { entry in
                    beginDownload(entry)
                },
                onShare: { entry in
                    beginShare(entry)
                },
                onRename: { entry in
                    beginRename(entry)
                },
                onMove: { entry in
                    beginMove(entry)
                },
                onEditPermissions: { entry in
                    guard canEditPermissions(for: entry) else { return }
                    beginEditPermissions(entry)
                },
                onDelete: { entry in
                    deleteTargetEntry = entry
                },
                onClose: nil,
                onSaveText: { entry, text in
                    try await browser.saveTextPreview(text, for: entry, serverId: server.id)
                }
            )
            .navigationTitle(snapshot.selectedEntry?.name ?? snapshot.viewerPayload?.entry.name ?? String(localized: "Preview"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let entry = snapshot.selectedEntry ?? snapshot.viewerPayload?.entry {
                        Menu {
                            inspectorActionMenu(entry)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .onChange(of: snapshot.currentPath) { _ in
            iOSSearchQuery = ""
        }
    }

    var iOSPreviewBinding: Binding<Bool> {
        Binding(
            get: { presentedPreviewPath != nil },
            set: { isPresented in
                if !isPresented {
                    presentedPreviewPath = nil
                }
            }
        )
    }

    func handleIOSEntryTap(_ entry: RemoteFileEntry) {
        Task {
            await browser.activate(entry, serverId: server.id)
            if browser.selectedEntryPath(for: server.id) == entry.path {
                await MainActor.run {
                    presentedPreviewPath = entry.path
                }
            }
        }
    }

    func iOSDisplayedEntries(_ snapshot: Snapshot) -> [RemoteFileEntry] {
        guard !trimmedIOSSearchQuery.isEmpty else { return snapshot.entries }

        return snapshot.entries.filter { entry in
            entry.name.localizedCaseInsensitiveContains(trimmedIOSSearchQuery)
                || (entry.symlinkTarget?.localizedCaseInsensitiveContains(trimmedIOSSearchQuery) ?? false)
        }
    }

    var trimmedIOSSearchQuery: String {
        iOSSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func iOSEmptyStateContent(
        _ snapshot: Snapshot,
        displayedEntries: [RemoteFileEntry]
    ) -> EmptyStateContent? {
        if let error = snapshot.directoryError {
            return EmptyStateContent(
                icon: "exclamationmark.triangle.fill",
                title: String(localized: "Browser Error"),
                message: error.errorDescription ?? error.localizedDescription
            )
        }

        if snapshot.isLoadingDirectory && snapshot.entries.isEmpty {
            return EmptyStateContent(
                icon: "spinner",
                title: String(localized: "Loading Files"),
                message: String(localized: "Fetching the contents of this remote directory.")
            )
        }

        if displayedEntries.isEmpty && !snapshot.isLoadingDirectory {
            return EmptyStateContent(
                icon: "magnifyingglass",
                title: String(localized: "No Results"),
                message: String(
                    format: String(localized: "No items match \"%@\"."),
                    trimmedIOSSearchQuery
                )
            )
        }

        return nil
    }

    func iOSBottomPanel(_ snapshot: Snapshot) -> some View {
        Group {
            if #available(iOS 26, *) {
                GlassEffectContainer(spacing: 10) {
                    iOSLiquidGlassBottomPanel(snapshot)
                }
            } else {
                iOSFallbackBottomPanel(snapshot)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Color.clear)
    }

    @available(iOS 26, *)
    func iOSLiquidGlassBottomPanel(_ snapshot: Snapshot) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await browser.goUp(server: server) }
            } label: {
                Image(systemName: "arrow.turn.up.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .foregroundStyle(.primary)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(snapshot.currentPath == "/")

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField(String(localized: "Search Files"), text: $iOSSearchQuery)
                    .font(.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($iOSSearchFieldFocused)
                    .onSubmit {
                        iOSSearchFieldFocused = false
                    }

                if !iOSSearchQuery.isEmpty {
                    Button {
                        iOSSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if iOSSearchFieldFocused {
                    Button {
                        iOSSearchFieldFocused = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if snapshot.isLoadingDirectory {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await browser.refresh(server: server) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
            .onTapGesture {
                iOSSearchFieldFocused = true
            }
            .glassEffect(.regular.interactive(), in: Capsule())

            Menu {
                browserActionMenu(currentPath: snapshot.currentPath)

                Divider()

                Toggle(
                    String(localized: "Show Hidden Files"),
                    isOn: Binding(
                        get: { browser.showHiddenFiles(for: server.id) },
                        set: { browser.setShowHiddenFiles($0, serverId: server.id) }
                    )
                )

                Picker(
                    String(localized: "Sort"),
                    selection: Binding(
                        get: { browser.sort(for: server.id) },
                        set: { browser.updateSort($0, serverId: server.id) }
                    )
                ) {
                    ForEach(RemoteFileSort.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 46, height: 46)
                    .foregroundStyle(.primary)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    func iOSFallbackBottomPanel(_ snapshot: Snapshot) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await browser.goUp(server: server) }
            } label: {
                Image(systemName: "arrow.turn.up.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .adaptiveGlassCircle()
            .disabled(snapshot.currentPath == "/")

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField(String(localized: "Search Files"), text: $iOSSearchQuery)
                    .font(.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($iOSSearchFieldFocused)
                    .onSubmit {
                        iOSSearchFieldFocused = false
                    }

                if !iOSSearchQuery.isEmpty {
                    Button {
                        iOSSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if iOSSearchFieldFocused {
                    Button {
                        iOSSearchFieldFocused = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if snapshot.isLoadingDirectory {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await browser.refresh(server: server) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
            .onTapGesture {
                iOSSearchFieldFocused = true
            }
            .adaptiveGlass()

            Menu {
                browserActionMenu(currentPath: snapshot.currentPath)

                Divider()

                Toggle(
                    String(localized: "Show Hidden Files"),
                    isOn: Binding(
                        get: { browser.showHiddenFiles(for: server.id) },
                        set: { browser.setShowHiddenFiles($0, serverId: server.id) }
                    )
                )

                Picker(
                    String(localized: "Sort"),
                    selection: Binding(
                        get: { browser.sort(for: server.id) },
                        set: { browser.updateSort($0, serverId: server.id) }
                    )
                ) {
                    ForEach(RemoteFileSort.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 46, height: 46)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .adaptiveGlassCircle()
        }
    }
}
#endif
