import SwiftUI

struct TrustedHostsSettingsView: View {
    @EnvironmentObject private var coordinator: KnownHostSettingsCoordinator
    @State private var resetTarget: TrustedHostResetTarget?

    var body: some View {
        Form {
            Section("Trusted Hosts") {
                if coordinator.knownHosts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("No Trusted Hosts", systemImage: "checkmark.shield")
                            .font(.headline)
                        Text("Hosts appear here after you approve their fingerprints.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                } else {
                    ForEach(coordinator.knownHosts) { knownHost in
                        TrustedHostSettingsRow(knownHost: knownHost) {
                            resetTarget = .host(knownHost)
                        }
                    }
                }
            }

            if !coordinator.knownHosts.isEmpty {
                Section {
                    Button(role: .destructive) {
                        resetTarget = .all
                    } label: {
                        Label("Reset Trusted SSH Hosts", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .tint(.red)
                } header: {
                    Text("Danger Zone")
                }
            }
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.page.trustedHosts")
        .alert(
            resetTarget?.title ?? "",
            isPresented: resetConfirmationPresented,
            presenting: resetTarget
        ) { target in
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                reset(target)
            }
        } message: { target in
            Text(target.message)
        }
        .onAppear {
            coordinator.loadHosts()
        }
    }

    private var resetConfirmationPresented: Binding<Bool> {
        Binding(
            get: { resetTarget != nil },
            set: { isPresented in
                if !isPresented {
                    resetTarget = nil
                }
            }
        )
    }

    private func reset(_ target: TrustedHostResetTarget) {
        switch target {
        case .host(let knownHost):
            coordinator.removeKnownHost(knownHost)
        case .all:
            coordinator.removeAllKnownHosts()
        }
        resetTarget = nil
    }
}

private struct TrustedHostSettingsRow: View {
    let knownHost: KnownHostSettingsItem
    let requestReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(knownHost.host)
                    .font(.headline)
                    .textSelection(.enabled)

                Spacer(minLength: 8)

                Button(action: requestReset) {
                    Label("Reset", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .tint(.red)
                .accessibilityIdentifier(
                    "vvterm.settings.trustedHosts.reset.\(knownHost.id)"
                )
            }

            HStack(spacing: 6) {
                Text("Port")
                Text(knownHost.port, format: .number)
                    .monospacedDigit()
                Text("·")
                    .accessibilityHidden(true)
                Label {
                    Text(
                        knownHost.lastSeenAt,
                        format: .relative(presentation: .named)
                    )
                } icon: {
                    Image(systemName: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Fingerprint")
                Text(knownHost.fingerprint)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("vvterm.settings.trustedHosts.entry.\(knownHost.id)")
    }
}

private enum TrustedHostResetTarget: Identifiable {
    case host(KnownHostSettingsItem)
    case all

    var id: String {
        switch self {
        case .host(let knownHost):
            knownHost.id
        case .all:
            "all"
        }
    }

    var title: String {
        switch self {
        case .host:
            String(localized: "Reset Trusted Host")
        case .all:
            String(localized: "Reset Trusted SSH Hosts")
        }
    }

    var message: String {
        switch self {
        case .host(let knownHost):
            String(
                format: String(localized: "VVTerm will forget the saved SSH fingerprint for %@. Verify it again when you reconnect."),
                knownHost.endpoint
            )
        case .all:
            String(localized: "VVTerm will forget all saved SSH host fingerprints on this device. The next connection to each host will trust the key it presents.")
        }
    }
}
