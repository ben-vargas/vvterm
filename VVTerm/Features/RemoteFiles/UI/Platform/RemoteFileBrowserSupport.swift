import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
import ObjectiveC.runtime
#endif

struct RemoteFileIOSRow: View {
    let entry: RemoteFileEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.iconName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(entry.type == .directory ? folderTint : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if entry.type == .directory {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []

        if let modifiedAt = entry.modifiedAt {
            parts.append(modifiedAt.formatted(date: .abbreviated, time: .omitted))
        }

        switch entry.type {
        case .directory:
            parts.append(String(localized: "Folder"))
        default:
            if let size = entry.size {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
        }

        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var folderTint: Color {
        Color.blue
    }
}

struct RemoteFileDownloadDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let sourceURL: URL

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    init(configuration: ReadConfiguration) throws {
        self.sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: sourceURL, options: .immediate)
    }
}

struct RemoteFileShareItem: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let title: String
}

#if os(macOS)
struct RemoteFileSharePicker: NSViewRepresentable {
    let item: RemoteFileShareItem
    let onComplete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.presentIfNeeded(item: item, from: nsView)
    }

    @MainActor
    final class Coordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        private let onComplete: () -> Void
        private var activeItemID: UUID?
        private var activePicker: NSSharingServicePicker?
        private var activeService: NSSharingService?
        private var didFinish = false

        init(onComplete: @escaping () -> Void) {
            self.onComplete = onComplete
        }

        func presentIfNeeded(item: RemoteFileShareItem, from view: NSView) {
            guard activeItemID != item.id else { return }

            activeItemID = item.id
            didFinish = false

            let picker = NSSharingServicePicker(items: [item.sourceURL])
            picker.delegate = self
            activePicker = picker

            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
            }
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            guard let service else {
                finish()
                return
            }

            activeService = service
            service.delegate = self
        }

        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            finish()
        }

        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
            finish()
        }

        private func finish() {
            guard !didFinish else { return }
            didFinish = true
            activePicker = nil
            activeService = nil
            activeItemID = nil
            onComplete()
        }
    }
}
#else
struct RemoteFileShareSheet: UIViewControllerRepresentable {
    let item: RemoteFileShareItem
    let onComplete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [item.sourceURL],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            context.coordinator.finish()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    final class Coordinator {
        private let onComplete: () -> Void
        private var didFinish = false

        init(onComplete: @escaping () -> Void) {
            self.onComplete = onComplete
        }

        func finish() {
            guard !didFinish else { return }
            didFinish = true
            onComplete()
        }
    }
}
#endif

struct RemoteFileDragPayload: Codable, Sendable {
    let serverId: UUID
    let entries: [RemoteFileEntry]

    init(serverId: UUID, entry: RemoteFileEntry) {
        self.init(serverId: serverId, entries: [entry])
    }

    init(serverId: UUID, entries: [RemoteFileEntry]) {
        self.serverId = serverId
        self.entries = entries
    }
}

extension UTType {
    static let vvtermRemoteFileEntry = UTType(exportedAs: "app.vivy.vvterm.remote-file-entry")
}

#if os(macOS)
@MainActor
final class MacOSMenuActionTarget: NSObject {
    private let actionHandler: () -> Void

    init(actionHandler: @escaping () -> Void) {
        self.actionHandler = actionHandler
    }

    @objc
    func performAction(_ sender: Any?) {
        actionHandler()
    }
}

struct MacOSWindowTopInsetBridge: NSViewRepresentable {
    @Binding var topInset: CGFloat

    func makeNSView(context: Context) -> WindowObserverView {
        WindowObserverView()
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        nsView.onWindowUpdate = { [topInset = _topInset] window in
            let safeArea = window.contentView?.safeAreaInsets
                ?? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            let measuredTopInset = max(
                window.frame.height - window.contentLayoutRect.height,
                safeArea.top
            )

            if abs(topInset.wrappedValue - measuredTopInset) > 0.5 {
                topInset.wrappedValue = measuredTopInset
            }
        }
        nsView.triggerUpdate()
    }

    static func dismantleNSView(_ nsView: WindowObserverView, coordinator: ()) {
        nsView.removeObservers()
    }

    final class WindowObserverView: NSView {
        var onWindowUpdate: ((NSWindow) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override var intrinsicContentSize: NSSize {
            .zero
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installObservers()
            triggerUpdate()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            triggerUpdate()
        }

        override func layout() {
            super.layout()
            triggerUpdate()
        }

        func triggerUpdate() {
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.onWindowUpdate?(window)
            }
        }

        func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
        }

        private func installObservers() {
            removeObservers()
            guard let window else { return }

            let center = NotificationCenter.default
            observers = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didMoveNotification,
                NSWindow.didBecomeKeyNotification
            ].map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.triggerUpdate()
                }
            }
        }

        deinit {
            removeObservers()
        }
    }
}

@MainActor
final class MacOSRemoteFileDragSessionStore {
    static let shared = MacOSRemoteFileDragSessionStore()

    var payload: RemoteFileDragPayload?

    private init() {}
}

struct MacOSRemoteFileTableView: NSViewRepresentable {
    let entries: [RemoteFileEntry]
    let currentPath: String
    let selectedPaths: Set<String>
    let sort: RemoteFileSort
    let sortDirection: RemoteFileSortDirection
    let onSelectionChange: @MainActor (Set<String>, NSEvent.ModifierFlags) -> Void
    let onActivate: @MainActor (RemoteFileEntry) -> Void
    let onSortChange: @MainActor (RemoteFileSort, RemoteFileSortDirection) -> Void
    let onUploadDroppedURLs: @MainActor ([URL], String) -> Void
    let onDropRemotePayload: @MainActor (RemoteFileDragPayload, String) -> Void
    let menuForEntry: @MainActor (RemoteFileEntry) -> NSMenu
    let menuForBackground: @MainActor () -> NSMenu
    let exportEntry: @MainActor (RemoteFileEntry, URL) async throws -> Void
    let fileTypeIdentifier: (RemoteFileEntry) -> String
    let kindLabel: (RemoteFileEntry) -> String
    let serverId: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(scrollView: scrollView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: MacOSRemoteFileTableView
        private let tableView = RemoteFileTableView()
        private let scrollView = NSScrollView()
        private var isUpdatingSelection = false
        private var promiseDelegates: [UUID: FilePromiseDelegate] = [:]
        private var currentDropRow: Int = -1
        private var currentDropOperation: NSTableView.DropOperation = .on

        init(_ parent: MacOSRemoteFileTableView) {
            self.parent = parent
        }

        func makeScrollView() -> NSScrollView {
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.documentView = tableView

            tableView.headerView = NSTableHeaderView()
            tableView.usesAlternatingRowBackgroundColors = true
            tableView.allowsMultipleSelection = true
            tableView.allowsColumnReordering = false
            tableView.allowsColumnResizing = true
            tableView.allowsTypeSelect = true
            tableView.focusRingType = .none
            tableView.style = .inset
            tableView.rowHeight = 32
            tableView.intercellSpacing = NSSize(width: 8, height: 0)
            tableView.backgroundColor = .clear
            tableView.selectionHighlightStyle = .regular
            tableView.draggingDestinationFeedbackStyle = .regular
            tableView.delegate = self
            tableView.dataSource = self
            tableView.menuProvider = { [weak self] row in
                guard let self else { return nil }
                if let row, row >= 0, row < self.parent.entries.count {
                    let entry = self.parent.entries[row]
                    self.selectRowIfNeeded(row)
                    return self.parent.menuForEntry(entry)
                }
                return self.parent.menuForBackground()
            }
            tableView.onSelectAll = { [weak self] in
                guard let self else { return }
                let allPaths = Set(self.parent.entries.map(\.id))
                self.parent.onSelectionChange(allPaths, [])
            }
            tableView.target = self
            tableView.doubleAction = #selector(handleDoubleAction(_:))
            let draggedTypes = Array(
                Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + [.fileURL])
            )
            tableView.registerForDraggedTypes(draggedTypes)
            tableView.setDraggingSourceOperationMask([.copy], forLocal: false)
            tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)

            configureColumns()
            applySortDescriptors()

            return scrollView
        }

        func update(scrollView: NSScrollView) {
            tableView.reloadData()
            applySortDescriptors()
            syncSelection()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.entries.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let entry = parent.entries[row]
            return entry.type == .symlink && entry.symlinkTarget != nil ? 38 : 30
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < parent.entries.count, let tableColumn else { return nil }
            let entry = parent.entries[row]

            switch ColumnID(rawValue: tableColumn.identifier.rawValue) {
            case .name:
                let view = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? NameCellView
                    ?? NameCellView()
                view.identifier = tableColumn.identifier
                view.configure(entry: entry)
                return view
            case .modifiedAt:
                return makeTextCell(
                    tableView: tableView,
                    identifier: tableColumn.identifier,
                    text: entry.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—",
                    alignment: .left
                )
            case .size:
                let sizeText = entry.type == .directory || entry.size == nil
                    ? "—"
                    : ByteCountFormatter.string(fromByteCount: Int64(entry.size ?? 0), countStyle: .file)
                return makeTextCell(
                    tableView: tableView,
                    identifier: tableColumn.identifier,
                    text: sizeText,
                    alignment: .right
                )
            case .kind:
                return makeTextCell(
                    tableView: tableView,
                    identifier: tableColumn.identifier,
                    text: parent.kindLabel(entry),
                    alignment: .left
                )
            case .none:
                return nil
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelection else { return }
            let selectedPaths: [String] = tableView.selectedRowIndexes.compactMap { index in
                guard parent.entries.indices.contains(index) else { return nil }
                return parent.entries[index].id
            }
            let selected = Set(selectedPaths)
            parent.onSelectionChange(selected, NSApp.currentEvent?.modifierFlags ?? [])
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let column = ColumnID(rawValue: descriptor.key ?? "") else { return }
            let direction: RemoteFileSortDirection = descriptor.ascending ? .ascending : .descending
            switch column {
            case .name:
                parent.onSortChange(.name, direction)
            case .modifiedAt:
                parent.onSortChange(.modifiedAt, direction)
            case .size:
                parent.onSortChange(.size, direction)
            case .kind:
                return
            }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.entries.indices.contains(row) else { return nil }
            let entry = parent.entries[row]
            let delegate = FilePromiseDelegate(
                entry: entry,
                fileTypeIdentifier: parent.fileTypeIdentifier(entry),
                export: parent.exportEntry
            )
            promiseDelegates[delegate.id] = delegate
            return delegate.makeProvider()
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            let draggedEntries = rowIndexes.compactMap { index -> RemoteFileEntry? in
                guard parent.entries.indices.contains(index) else { return nil }
                return parent.entries[index]
            }
            MacOSRemoteFileDragSessionStore.shared.payload = RemoteFileDragPayload(
                serverId: parent.serverId,
                entries: draggedEntries
            )
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            MacOSRemoteFileDragSessionStore.shared.payload = nil
            promiseDelegates.removeAll()
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            retargetDrop(on: tableView, proposedRow: row, dropOperation: dropOperation)
            let destinationPath = destinationPath(
                for: currentDropRow,
                dropOperation: currentDropOperation
            )
            guard destinationPath != nil else { return [] }

            if let source = MacOSRemoteFileDragSessionStore.shared.payload, !source.entries.isEmpty {
                return source.serverId == parent.serverId ? .move : .copy
            }

            let fileURLs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            return fileURLs.isEmpty ? [] : .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let destinationPath = destinationPath(
                for: currentDropRow,
                dropOperation: currentDropOperation
            ) else { return false }

            if let payload = MacOSRemoteFileDragSessionStore.shared.payload, !payload.entries.isEmpty {
                parent.onDropRemotePayload(payload, destinationPath)
                return true
            }

            let fileURLs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            guard !fileURLs.isEmpty else { return false }
            parent.onUploadDroppedURLs(fileURLs, destinationPath)
            return true
        }

        @objc
        private func handleDoubleAction(_ sender: Any?) {
            let row = tableView.clickedRow
            guard row >= 0, parent.entries.indices.contains(row) else { return }
            parent.onActivate(parent.entries[row])
        }

        private func destinationPath(for row: Int, dropOperation: NSTableView.DropOperation) -> String? {
            if row == -1 {
                return parent.currentPath
            }

            if dropOperation == .on, row >= 0, parent.entries.indices.contains(row) {
                let entry = parent.entries[row]
                return entry.type == .directory ? entry.path : nil
            }

            return parent.currentPath
        }

        private func retargetDrop(
            on tableView: NSTableView,
            proposedRow row: Int,
            dropOperation: NSTableView.DropOperation
        ) {
            guard row >= 0, parent.entries.indices.contains(row) else {
                currentDropRow = -1
                currentDropOperation = .on
                tableView.setDropRow(-1, dropOperation: .on)
                return
            }

            let entry = parent.entries[row]
            if entry.type == .directory {
                currentDropRow = row
                currentDropOperation = .on
                tableView.setDropRow(row, dropOperation: .on)
            } else if dropOperation == .above {
                currentDropRow = -1
                currentDropOperation = .on
                tableView.setDropRow(-1, dropOperation: .on)
            } else {
                currentDropRow = row
                currentDropOperation = dropOperation
            }
        }

        private func syncSelection() {
            let rowIndexes = IndexSet(
                parent.entries.enumerated().compactMap { index, entry in
                    parent.selectedPaths.contains(entry.id) ? index : nil
                }
            )
            guard tableView.selectedRowIndexes != rowIndexes else { return }
            isUpdatingSelection = true
            tableView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
            isUpdatingSelection = false
        }

        private func configureColumns() {
            tableView.tableColumns.forEach(tableView.removeTableColumn)

            tableView.addTableColumn(makeColumn(id: .name, title: String(localized: "Name"), width: 280, minWidth: 140))
            tableView.addTableColumn(makeColumn(id: .modifiedAt, title: String(localized: "Date Modified"), width: 200, minWidth: 120))
            tableView.addTableColumn(makeColumn(id: .size, title: String(localized: "Size"), width: 90, minWidth: 60))
            tableView.addTableColumn(makeColumn(id: .kind, title: String(localized: "Kind"), width: 150, minWidth: 90))
        }

        private func makeColumn(id: ColumnID, title: String, width: CGFloat, minWidth: CGFloat) -> NSTableColumn {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
            column.title = title
            column.width = width
            column.minWidth = minWidth
            column.resizingMask = .autoresizingMask
            column.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: sortAscending(for: id))
            return column
        }

        private func sortAscending(for column: ColumnID) -> Bool {
            switch column {
            case .name:
                return parent.sort == .name ? parent.sortDirection == .ascending : true
            case .modifiedAt:
                return parent.sort == .modifiedAt ? parent.sortDirection == .ascending : false
            case .size:
                return parent.sort == .size ? parent.sortDirection == .ascending : false
            case .kind:
                return true
            }
        }

        private func applySortDescriptors() {
            guard let targetColumn = ColumnID(sort: parent.sort),
                  let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(targetColumn.rawValue)) else {
                return
            }

            let targetDescriptor = NSSortDescriptor(
                key: targetColumn.rawValue,
                ascending: parent.sortDirection == .ascending
            )
            if tableView.sortDescriptors != [targetDescriptor] {
                tableView.sortDescriptors = [targetDescriptor]
            }
            column.sortDescriptorPrototype = targetDescriptor
        }

        private func makeTextCell(
            tableView: NSTableView,
            identifier: NSUserInterfaceItemIdentifier,
            text: String,
            alignment: NSTextAlignment
        ) -> NSView {
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? TextCellView ?? TextCellView()
            cell.identifier = identifier
            cell.configure(text: text, alignment: alignment)
            return cell
        }

        private func selectRowIfNeeded(_ row: Int) {
            guard row >= 0 else { return }
            if !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
    }

    private enum ColumnID: String {
        case name
        case modifiedAt
        case size
        case kind

        init?(sort: RemoteFileSort) {
            switch sort {
            case .name: self = .name
            case .modifiedAt: self = .modifiedAt
            case .size: self = .size
            }
        }
    }

    final class RemoteFileTableView: NSTableView {
        var menuProvider: ((Int?) -> NSMenu?)?
        var onSelectAll: (() -> Void)?

        override func menu(for event: NSEvent) -> NSMenu? {
            let location = convert(event.locationInWindow, from: nil)
            let row = self.row(at: location)
            return menuProvider?(row >= 0 ? row : nil)
        }

        override func selectAll(_ sender: Any?) {
            super.selectAll(sender)
            onSelectAll?()
        }
    }

    final class NameCellView: NSTableCellView {
        private let iconView = NSImageView()
        private let titleField = NSTextField(labelWithString: "")
        private let subtitleField = NSTextField(labelWithString: "")

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)

            titleField.translatesAutoresizingMaskIntoConstraints = false
            titleField.lineBreakMode = .byTruncatingTail
            titleField.font = .systemFont(ofSize: NSFont.systemFontSize)

            subtitleField.translatesAutoresizingMaskIntoConstraints = false
            subtitleField.lineBreakMode = .byTruncatingTail
            subtitleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            subtitleField.textColor = .secondaryLabelColor

            let stack = NSStackView(views: [titleField, subtitleField])
            stack.orientation = .vertical
            stack.spacing = 1
            stack.alignment = .leading
            stack.translatesAutoresizingMaskIntoConstraints = false

            addSubview(iconView)
            addSubview(stack)

            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 18),
                iconView.heightAnchor.constraint(equalToConstant: 18),

                stack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(entry: RemoteFileEntry) {
            titleField.stringValue = entry.name
            subtitleField.stringValue = entry.type == .symlink ? (entry.symlinkTarget ?? "") : ""
            subtitleField.isHidden = subtitleField.stringValue.isEmpty
            iconView.image = NSImage(systemSymbolName: entry.iconName, accessibilityDescription: entry.name)
            iconView.contentTintColor = entry.type == .directory ? .systemBlue : .secondaryLabelColor
        }
    }

    final class TextCellView: NSTableCellView {
        private let label = NSTextField(labelWithString: "")

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.textColor = .secondaryLabelColor
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func configure(text: String, alignment: NSTextAlignment) {
            label.stringValue = text
            label.alignment = alignment
        }
    }

    final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
        let id = UUID()
        private let entry: RemoteFileEntry
        private let fileTypeIdentifier: String
        private let export: @MainActor (RemoteFileEntry, URL) async throws -> Void

        init(
            entry: RemoteFileEntry,
            fileTypeIdentifier: String,
            export: @escaping @MainActor (RemoteFileEntry, URL) async throws -> Void
        ) {
            self.entry = entry
            self.fileTypeIdentifier = fileTypeIdentifier
            self.export = export
        }

        func makeProvider() -> NSFilePromiseProvider {
            NSFilePromiseProvider(fileType: fileTypeIdentifier, delegate: self)
        }

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
            .main
        }

        func promisedFileName(for fileType: String) -> String {
            let fallbackName = entry.type == .directory ? "Folder" : "download"
            let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedName.isEmpty ? fallbackName : trimmedName
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            promisedFileName(for: fileType)
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            Task { @MainActor in
                do {
                    try await export(entry, url)
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }
    }

}

private var macOSMenuActionTargetAssociationKey: UInt8 = 0

@MainActor
func makeMacOSMenuItem(
    title: String,
    systemImage: String? = nil,
    keyEquivalent: String = "",
    modifierMask: NSEvent.ModifierFlags = [],
    action: @escaping () -> Void
) -> NSMenuItem {
    let item = NSMenuItem(
        title: title,
        action: #selector(MacOSMenuActionTarget.performAction(_:)),
        keyEquivalent: keyEquivalent
    )
    item.keyEquivalentModifierMask = modifierMask
    if let systemImage {
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
    }

    let target = MacOSMenuActionTarget(actionHandler: action)
    item.target = target
    objc_setAssociatedObject(
        item,
        &macOSMenuActionTargetAssociationKey,
        target,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    return item
}

func makeMacOSSeparatorMenuItem() -> NSMenuItem {
    .separator()
}
#endif
