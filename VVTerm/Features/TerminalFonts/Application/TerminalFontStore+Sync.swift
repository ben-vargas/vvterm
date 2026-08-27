import Foundation
import os.log

extension TerminalFontStore {
    func startSynchronizationIfNeeded() {
        guard dependencies.startsSynchronization else { return }
        lifecycleObserverID = dependencies.syncLifecycle.observe { [weak self] event in
            self?.handleSyncLifecycleEvent(event)
        }
        syncTask = makeCloudSyncTask()
    }

    func enqueueFont(_ font: TerminalFont) {
        guard dependencies.isSyncEnabled() else { return }
        let queue = dependencies.mutationQueue
        do {
            try queue.enqueueTerminalFontUpsert(font)
        } catch {
            logger.error("Failed to queue custom font sync: \(error.localizedDescription)")
            return
        }
        Task { @MainActor in
            await queue.drainPendingMutations()
        }
    }

    func enqueuePreference(_ preference: TerminalFontPreference) {
        guard dependencies.isSyncEnabled() else { return }
        let queue = dependencies.mutationQueue
        do {
            try queue.enqueueTerminalFontPreferenceUpsert(preference)
        } catch {
            logger.error("Failed to queue font preference sync: \(error.localizedDescription)")
            return
        }
        Task { @MainActor in
            await queue.drainPendingMutations()
        }
    }

    func synchronizeWithCloud() async throws {
        try Task.checkCancellation()
        guard dependencies.isSyncEnabled() else { return }

        let localFonts = fontRecords
        let remoteFonts = try await dependencies.cloud.fetchTerminalFonts()
        try Task.checkCancellation()
        guard dependencies.isSyncEnabled() else { throw CancellationError() }

        mergeRemoteFonts(remoteFonts)
        clearSelections(providedBy: fontRecords.filter(\.isDeleted))
        try enqueueLocalFonts(localFonts, remoteFonts: remoteFonts)

        let remotePreference = try await dependencies.cloud.fetchTerminalFontPreference()
        try Task.checkCancellation()
        guard dependencies.isSyncEnabled() else { throw CancellationError() }
        try mergePreference(remotePreference)

        await dependencies.mutationQueue.drainPendingMutations()
    }

    private func enqueueLocalFonts(
        _ localFonts: [TerminalFont],
        remoteFonts: [TerminalFont]
    ) throws {
        let remoteByID = Dictionary(
            remoteFonts.map { ($0.id, $0) },
            uniquingKeysWith: { first, second in
                first.updatedAt >= second.updatedAt ? first : second
            }
        )

        for localFont in localFonts {
            if let remoteFont = remoteByID[localFont.id],
               remoteFont.updatedAt >= localFont.updatedAt {
                continue
            }
            guard localFont.isDeleted
                    || dependencies.repository.existingFileURL(for: localFont) != nil else {
                continue
            }
            try dependencies.mutationQueue.enqueueTerminalFontUpsert(localFont)
        }
    }

    private func mergePreference(_ remotePreference: TerminalFontPreference?) throws {
        var local = preference
        guard let remotePreference else {
            if local.updatedAt == .distantPast {
                local = TerminalFontPreference(
                    primaryFamily: local.primaryFamily,
                    cjkFamily: local.cjkFamily,
                    updatedAt: dependencies.now()
                )
                applyPreference(local, enqueueForSync: false)
            }
            try dependencies.mutationQueue.enqueueTerminalFontPreferenceUpsert(local)
            return
        }

        let remote = try TerminalFontValidator.validatePreference(remotePreference)
        if remote.updatedAt > local.updatedAt {
            applyPreference(remote, enqueueForSync: false)
        } else if local.updatedAt > remote.updatedAt {
            try dependencies.mutationQueue.enqueueTerminalFontPreferenceUpsert(local)
        }
    }

    private func makeCloudSyncTask() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await synchronizeWithCloud()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, dependencies.isSyncEnabled() else { return }
                logger.warning("Custom font CloudKit sync failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleSyncLifecycleEvent(_ event: CloudKitSyncLifecycleEvent) {
        switch event {
        case .foreground, .syncEnabled:
            syncTask?.cancel()
            syncTask = makeCloudSyncTask()
        case .syncDisabled:
            syncTask?.cancel()
            syncTask = nil
        }
    }
}
