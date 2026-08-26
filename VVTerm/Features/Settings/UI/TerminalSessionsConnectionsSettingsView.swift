import SwiftUI

struct TerminalSessionsConnectionsSettingsView: View {
    let backends: [RemoteSessionBackendMetadata]

    @AppStorage(TerminalRemoteSessionDefaults.enabledKey) private var remoteSessionEnabledDefault = true
    @AppStorage(TerminalRemoteSessionDefaults.backendIdentifierKey)
    private var remoteSessionBackendIdentifierRaw = RemoteSessionBackendIdentifier.tmux.rawValue
    @AppStorage(TerminalRemoteSessionDefaults.startupBehaviorKey)
    private var remoteSessionStartupBehaviorRaw = RemoteSessionStartupBehavior.ask.rawValue
    @AppStorage(SSHRuntimeSettings.keepAliveEnabledKey) private var keepAliveEnabled = true
    @AppStorage(SSHRuntimeSettings.keepAliveIntervalKey) private var keepAliveInterval = 30
    @AppStorage(TerminalDefaults.sshAutoReconnectKey) private var autoReconnect = true

    private var remoteSessionBackendIdentifierBinding: Binding<RemoteSessionBackendIdentifier> {
        Binding(
            get: {
                let stored = RemoteSessionBackendIdentifier(rawValue: remoteSessionBackendIdentifierRaw)
                if backends.contains(where: { $0.identifier == stored }) {
                    return stored
                }
                if backends.contains(where: { $0.identifier == .tmux }) {
                    return .tmux
                }
                return backends.first?.identifier ?? .tmux
            },
            set: { remoteSessionBackendIdentifierRaw = $0.rawValue }
        )
    }

    private var remoteSessionStartupBehaviorBinding: Binding<RemoteSessionStartupBehavior> {
        Binding(
            get: {
                RemoteSessionStartupBehavior(
                    persistedRawValue: remoteSessionStartupBehaviorRaw
                ) ?? .ask
            },
            set: { remoteSessionStartupBehaviorRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            TerminalSessionPlatformSettingsSection()

            Section {
                Toggle("Use persistent sessions by default", isOn: $remoteSessionEnabledDefault)

                if remoteSessionEnabledDefault {
                    Picker("Use", selection: remoteSessionBackendIdentifierBinding) {
                        ForEach(backends, id: \.identifier) { backend in
                            RemoteSessionBackendLabel(backend: backend)
                                .tag(backend.identifier)
                        }
                    }

                    Picker("On connect", selection: remoteSessionStartupBehaviorBinding) {
                        ForEach(RemoteSessionStartupBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                }
            } header: {
                Text("Session Persistence")
            } footer: {
                Text("These defaults apply to new servers. You can override them in server settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("SSH Connection") {
                Toggle("Auto-reconnect on disconnect", isOn: $autoReconnect)
                Toggle("Send keep-alive packets", isOn: $keepAliveEnabled)

                if keepAliveEnabled {
                    Stepper("Interval: \(keepAliveInterval)s", value: $keepAliveInterval, in: 10...120, step: 10)
                }
            }
        }
        .formStyle(.grouped)
        .adaptiveSoftScrollEdges()
        .accessibilityIdentifier("vvterm.settings.page.sessionsAndConnections")
    }
}
