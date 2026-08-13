import SwiftUI

struct TrustedHostsSettingsView: View {
    @EnvironmentObject private var coordinator: KnownHostSettingsCoordinator
    @State private var showingResetConfirmation = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Trusted Hosts") {
                    Text(coordinator.knownHostCount, format: .number)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(knownHostsExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(role: .destructive) {
                    showingResetConfirmation = true
                } label: {
                    Label("Reset Trusted SSH Hosts", systemImage: "trash")
                        .foregroundStyle(.red)
                }
                .tint(.red)
                .disabled(coordinator.knownHostCount == 0)
            } header: {
                Text("Danger Zone")
            }
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.page.trustedHosts")
        .alert("Reset Trusted SSH Hosts", isPresented: $showingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                coordinator.removeAllKnownHosts()
            }
        } message: {
            Text("VVTerm will forget all saved SSH host fingerprints on this device. The next connection to each host will trust the key it presents.")
        }
        .onAppear {
            coordinator.loadCount()
        }
    }

    private var knownHostsExplanation: String {
        let count = Int64(coordinator.knownHostCount)
        if count == 1 {
            return String(localized: "VVTerm has 1 trusted SSH host on this device. Resetting trusted hosts makes VVTerm trust the host key presented on the next connection.")
        }
        return String(
            format: String(localized: "VVTerm has %lld trusted SSH hosts on this device. Resetting trusted hosts makes VVTerm trust the host key presented on the next connection."),
            count
        )
    }
}
