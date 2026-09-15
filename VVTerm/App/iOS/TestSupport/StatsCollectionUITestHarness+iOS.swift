#if os(iOS) && DEBUG
import SwiftUI

/// Exercises the production dashboard and collector through the terminal's
/// safe-area switch, with fixed samples in place of SSH work.
struct StatsCollectionUITestHarness: View {
    @State private var selectedView = ConnectionViewTabID.terminal
    @StateObject private var collector: ServerStatsCollector
    private let volumeVisibilityStore = ServerVolumeVisibilityStore(
        persistence: VolumePreferences()
    )
    private static let server = Server(
        workspaceId: UUID(), name: "Stats test", host: "stats.example.test", username: "test"
    )

    init() {
        let session = CollectionSession()
        _collector = StateObject(wrappedValue: ServerStatsCollector(
            dependencies: ServerStatsCollectorDependencies(
                makeOwnedConnection: { session },
                makeSession: { _, _, _ in session },
                makeAttemptID: UUID.init,
                waitForNextPoll: { try await Task.sleep(for: .seconds(1)) }
            )
        ))
    }

    var body: some View {
        VStack {
            Picker("View", selection: $selectedView) {
                Text("Terminal").tag(ConnectionViewTabID.terminal)
                Text("Stats").tag(ConnectionViewTabID.stats)
                Text("Files").tag(ConnectionViewTabID.files)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("vvterm.stats.collection.tabs")

            Text("Collection")
                .accessibilityIdentifier("vvterm.stats.collection.state")
                .accessibilityValue(Text(verbatim:
                    "polling=\(collector.collectionState.isPolling);sample=\(collector.stats.timestamp.timeIntervalSinceReferenceDate)"
                ))

            tabContent
                .modifier(TerminalKeyboardSafeAreaModifier(isEnabled: selectedView == .terminal))
        }
        .onDisappear { collector.stopCollecting() }
    }

    private var tabContent: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedView {
                case .terminal:
                    Text("Terminal test content")
                case .files:
                    Text("Files test content")
                case .stats:
                    ServerStatsDashboard(
                        server: Self.server,
                        backgroundColor: .black,
                        sharedClientProvider: { nil },
                        statsCollector: collector,
                        preferences: .defaultValue(lastWriterDeviceId: "ui-test"),
                        volumeVisibilityStore: volumeVisibilityStore,
                        securityApprovalActions: .init(
                            approve: { _ in .failed(.unavailable) }, reject: { _ in }
                        ),
                        isDockerUnlocked: false,
                        showAppearanceSettings: {},
                        showDockerUpgrade: {}
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transaction { $0.animation = nil }
        }
    }

    @MainActor
    private final class VolumePreferences: ServerVolumeVisibilityPreferencesPersisting {
        func loadPreferences() -> ServerVolumeVisibilityPreferences { .init() }
        func savePreferences(_ preferences: ServerVolumeVisibilityPreferences) {}
    }

    @MainActor
    private final class CollectionSession: ServerStatsConnectionReference, ServerStatsCollectionSession {
        var identity: ServerStatsConnectionIdentity { ServerStatsConnectionIdentity(self) }
        var connectionIdentity: ServerStatsConnectionIdentity { identity }
        let ownership = ServerStatsClientOwnership.owned

        func runCollection(
            _ operation: @MainActor @Sendable @escaping () async throws -> Void
        ) async throws {
            try await operation()
        }

        func disconnect() async {}
        func prepareIfNeeded() async -> ServerStatsCollectionPreparation? { nil }

        func collectStats(collectDocker: Bool) async throws -> ServerStats {
            var stats = StatsPreviewFixture.stats
            stats.timestamp = Date()
            return stats
        }

        func terminateProcess(_ process: ProcessInfo) async throws {}
        func loadProcesses(fallback: [ProcessInfo]) async throws -> [ProcessInfo] { fallback }
        func loadDockerStats(fallback: DockerStats) async -> DockerStats { fallback }
        func loadStorageHealth(for volume: VolumeInfo) async throws -> StorageHealthResult {
            .unavailable(.unsupported)
        }

        func performDockerAction(
            _ action: DockerContainerAction,
            on container: DockerContainer,
            fallback: DockerStats
        ) async throws -> DockerStats { fallback }
    }
}
#endif
