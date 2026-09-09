import SwiftUI

private struct OpenRemoteTerminalFileKey: EnvironmentKey {
    static let defaultValue: (@MainActor (URL) -> Bool)? = nil
}

extension EnvironmentValues {
    var openRemoteTerminalFile: (@MainActor (URL) -> Bool)? {
        get { self[OpenRemoteTerminalFileKey.self] }
        set { self[OpenRemoteTerminalFileKey.self] = newValue }
    }
}

struct TerminalLinkConfirmationModifier: ViewModifier {
    @ObservedObject var coordinator: TerminalLinkCoordinator
    let isActive: Bool
    @Environment(\.openRemoteTerminalFile) private var openRemoteFile
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: {
                switch coordinator.presentation {
                case .confirmation, .failure: true
                case .opening, nil: false
                }
            },
            set: { if !$0 { coordinator.dismissAlert() } }
        )
    }

    private var title: String {
        if case .failure = coordinator.presentation {
            return String(localized: "Unable to Open Link")
        }
        return String(localized: "Open Link")
    }

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: alertIsPresented) {
                switch coordinator.presentation {
                case .confirmation:
                    Button("Cancel", role: .cancel) { coordinator.cancel() }
                    Button("Open") {
                        guard isActive else { coordinator.cancel(); return }
                        coordinator.open { url, completion in
                            // Let SwiftUI dismiss confirmation before reporting an immediate failure.
                            let finish: (Bool) -> Void = { accepted in
                                DispatchQueue.main.async { completion(accepted) }
                            }
                            if url.isFileURL {
                                finish(openRemoteFile?(url) ?? false)
                            } else {
                                openURL(url, completion: finish)
                            }
                        }
                    }
                case .failure:
                    Button("OK", role: .cancel) { coordinator.cancel() }
                case .opening, nil:
                    EmptyView()
                }
            } message: {
                switch coordinator.presentation {
                case .confirmation(let request):
                    if request.url.isFileURL {
                        Text(verbatim: String(localized: "Open in Files on the current server?")
                             + "\n\n" + request.url.absoluteString)
                    } else {
                        Text(request.url.absoluteString)
                    }
                case .failure: Text("The link could not be opened.")
                case .opening, nil: EmptyView()
                }
            }
            .onChange(of: isActive) { if !$0 { coordinator.cancel() } }
            .onChange(of: scenePhase) { if $0 == .background { coordinator.cancel() } }
            .onDisappear { coordinator.cancel() }
    }
}
