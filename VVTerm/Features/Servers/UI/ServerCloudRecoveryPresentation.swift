import SwiftUI

struct ServerCloudRecoveryPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let resolve: (AmbiguousCloudRecoveryChoice) async throws -> Void
    @State private var recoveryFailure: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                String(localized: "Cloud data needs review"),
                isPresented: $isPresented,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Keep Local Data")) {
                    startRecovery(.keepLocal)
                }
                Button(String(localized: "Upload Local Data")) {
                    startRecovery(.uploadLocal)
                }
                Button(String(localized: "Replace with Cloud Data"), role: .destructive) {
                    startRecovery(.replaceWithCloud)
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(
                    String(
                        localized: "VVTerm could not confirm that missing local items were intentionally removed."
                    )
                )
            }
            .alert(
                String(localized: "Recovery Failed"),
                isPresented: Binding(
                    get: { recoveryFailure != nil },
                    set: { if !$0 { recoveryFailure = nil } }
                )
            ) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(recoveryFailure ?? "")
            }
    }

    private func startRecovery(_ choice: AmbiguousCloudRecoveryChoice) {
        Task {
            do {
                try await resolve(choice)
            } catch {
                recoveryFailure = error.localizedDescription
            }
        }
    }
}
