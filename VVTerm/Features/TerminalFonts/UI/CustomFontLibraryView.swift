import SwiftUI
import UniformTypeIdentifiers

struct CustomFontLibraryView: View {
    enum Presentation {
        case importer
        case deleteConfirmation(TerminalFont.ID)
        case proUpgrade
        case error(String)
    }

    #if os(macOS)
    let onClose: () -> Void
    #endif

    @EnvironmentObject var fontStore: TerminalFontStore
    @EnvironmentObject var storeManager: StoreManager
    @State var presentation: Presentation?

    #if os(macOS)
    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }
    #else
    init() {}
    #endif

    var body: some View {
        platformBody
            .fileImporter(
                isPresented: importerBinding,
                allowedContentTypes: supportedContentTypes,
                allowsMultipleSelection: false,
                onCompletion: handleImport
            )
            .alert("Delete Custom Font?", isPresented: deleteAlertBinding) {
                Button("Delete", role: .destructive) {
                    if let fontID = fontIDPendingDeletion {
                        fontStore.deleteFont(id: fontID)
                    }
                    presentation = nil
                }
                Button("Cancel", role: .cancel) {
                    presentation = nil
                }
            } message: {
                Text("This removes the font from VVTerm and synced devices.")
            }
            .alert("Custom Font", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(presentedError ?? "")
            }
            .proFeatureAlert(
                title: String(localized: "Custom Fonts"),
                message: String(localized: "Custom and CJK fonts require Pro."),
                source: .settings,
                isPresented: proBinding
            )
            .adaptiveSoftScrollEdges()
    }

    var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "textformat")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No Custom Fonts")
                .font(.headline.weight(.semibold))
            Text("Import a TTF, OTF, TTC, or OTC font file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    var libraryNote: some View {
        Text("Fonts stay inside VVTerm. iCloud Sync keeps them on your devices.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    func requestImport() {
        guard storeManager.allowsProFeatures else {
            presentation = .proUpgrade
            return
        }
        presentation = .importer
    }

    func deleteButton(for font: TerminalFont) -> some View {
        Button("Delete", role: .destructive) {
            presentation = .deleteConfirmation(font.id)
        }
    }

    private var supportedContentTypes: [UTType] {
        TerminalFont.FileFormat.allCases.compactMap {
            UTType(filenameExtension: $0.rawValue)
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { fontIDPendingDeletion != nil },
            set: { if !$0 { presentation = nil } }
        )
    }

    private var importerBinding: Binding<Bool> {
        Binding(
            get: {
                if case .importer? = presentation { return true }
                return false
            },
            set: { if !$0 { presentation = nil } }
        )
    }

    private var proBinding: Binding<Bool> {
        Binding(
            get: {
                if case .proUpgrade? = presentation { return true }
                return false
            },
            set: { if !$0 { presentation = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { presentedError != nil },
            set: { if !$0 { presentation = nil } }
        )
    }

    private var fontIDPendingDeletion: TerminalFont.ID? {
        if case .deleteConfirmation(let fontID)? = presentation { return fontID }
        return nil
    }

    private var presentedError: String? {
        if case .error(let message)? = presentation { return message }
        return nil
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessedSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if accessedSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                try fontStore.importFont(
                    from: url,
                    allowsProFeatures: storeManager.allowsProFeatures
                )
            } catch {
                present(error)
            }
        case .failure(let error):
            let cocoaError = error as NSError
            guard cocoaError.domain != NSCocoaErrorDomain
                    || cocoaError.code != NSUserCancelledError else {
                return
            }
            present(error)
        }
    }

    private func present(_ error: Error) {
        if (error as? TerminalFontValidationError) == .requiresPro {
            presentation = .proUpgrade
        } else {
            presentation = .error(error.localizedDescription)
        }
    }
}

extension CustomFontLibraryView {
    struct FontRow: View {
        let font: TerminalFont
        let isAvailable: Bool

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: "textformat")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(font.displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !isAvailable {
                        Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Spacer(minLength: 8)
            }
        }

        private var detail: String {
            var parts = [font.originalFilename]
            if font.familyNames.count > 1 {
                parts.append(
                    String(
                        format: String(localized: "%lld families"),
                        Int64(font.familyNames.count)
                    )
                )
            }
            parts.append(
                ByteCountFormatter.string(
                    fromByteCount: font.fileSize,
                    countStyle: .file
                )
            )
            return parts.joined(separator: " · ")
        }
    }
}
