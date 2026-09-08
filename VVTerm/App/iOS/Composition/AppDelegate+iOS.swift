#if os(iOS)
import UIKit
import os.log

nonisolated enum AppSceneLifecyclePolicy {
    static func shouldHandleBackgroundTransition(
        connectedSceneStates: [UIScene.ActivationState]
    ) -> Bool {
        !connectedSceneStates.contains { state in
            switch state {
            case .foregroundActive, .foregroundInactive:
                true
            case .background, .unattached:
                false
            @unknown default:
                true
            }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    private let logger = Logger(subsystem: "app.vivy.VivyTerm", category: "Lifecycle")
    private var lastForegroundSyncAt: Date = .distantPast
    private let foregroundSyncMinimumInterval: TimeInterval = 20
    private var resumableTerminalLifecycleTask: Task<Void, Never>?
    private weak var tabManager: TerminalTabManager?
    private weak var cloudDataSync: AppCloudDataSyncCoordinator?
    private weak var appLockManager: AppLockManager?
    private var lifecycleDependencies: AppLifecycleDependencies?

    func configure(
        tabManager: TerminalTabManager,
        cloudDataSync: AppCloudDataSyncCoordinator,
        appLockManager: AppLockManager,
        lifecycleDependencies: AppLifecycleDependencies
    ) {
        if let currentManager = self.tabManager {
            precondition(currentManager === tabManager, "AppDelegate received a different terminal manager")
        }
        if let currentManager = self.cloudDataSync {
            precondition(currentManager === cloudDataSync, "AppDelegate received a different cloud sync coordinator")
        }
        if let currentManager = self.appLockManager {
            precondition(currentManager === appLockManager, "AppDelegate received a different app lock manager")
        }
        self.tabManager = tabManager
        self.cloudDataSync = cloudDataSync
        self.appLockManager = appLockManager
        self.lifecycleDependencies = lifecycleDependencies
    }

    private var configuredTabManager: TerminalTabManager {
        guard let tabManager else {
            preconditionFailure("AppDelegate must be configured with a terminal manager")
        }
        return tabManager
    }

    private var configuredCloudDataSync: AppCloudDataSyncCoordinator {
        guard let cloudDataSync else {
            preconditionFailure("AppDelegate must be configured with a cloud sync coordinator")
        }
        return cloudDataSync
    }

    private var configuredAppLockManager: AppLockManager {
        guard let appLockManager else {
            preconditionFailure("AppDelegate must be configured with an app lock manager")
        }
        return appLockManager
    }

    private var configuredLifecycleDependencies: AppLifecycleDependencies {
        guard let lifecycleDependencies else {
            preconditionFailure("AppDelegate must be configured with lifecycle dependencies")
        }
        return lifecycleDependencies
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let subscribeToRemoteChanges = configuredLifecycleDependencies.subscribeToRemoteChanges
        Task {
            await subscribeToRemoteChanges()
        }
        application.registerForRemoteNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidBecomeActive(_:)),
            name: UIScene.didActivateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneWillDeactivate(_:)),
            name: UIScene.willDeactivateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidEnterBackground(_:)),
            name: UIScene.didEnterBackgroundNotification,
            object: nil
        )

        return true
    }

    @objc
    private func sceneDidBecomeActive(_ notification: Notification) {
        guard notificationBelongsToConnectedApplicationScene(notification) else { return }

        handleSceneDidBecomeActive(
            refreshNetwork: configuredLifecycleDependencies.refreshNetwork,
            resume: { queueResumableTerminalResume() }
        )

        guard SyncSettings.isEnabled else { return }

        let now = Date()
        guard now.timeIntervalSince(lastForegroundSyncAt) >= foregroundSyncMinimumInterval else { return }
        lastForegroundSyncAt = now

        Task {
            do {
                try await configuredCloudDataSync.refresh()
            } catch is CancellationError {
                return
            } catch {
                logger.error("Automatic cloud refresh failed: \(error.localizedDescription)")
            }
        }
    }

    func handleSceneDidBecomeActive(
        refreshNetwork: () -> Void,
        resume: () -> Void
    ) {
        refreshNetwork()
        resume()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard SyncSettings.isEnabled else {
            completionHandler(.noData)
            return
        }

        logger.info("Cloud change notification received")
        Task {
            do {
                try await configuredCloudDataSync.refresh()
                completionHandler(.newData)
            } catch is CancellationError {
                completionHandler(.noData)
            } catch {
                logger.error("Push cloud refresh failed: \(error.localizedDescription)")
                completionHandler(.failed)
            }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        logger.info("Cloud push registration succeeded")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        logger.error("Cloud push registration failed: \(error.localizedDescription)")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        handleApplicationWillTerminate()
    }

    @discardableResult
    func handleApplicationWillTerminate() -> Bool {
        configuredTabManager.beginApplicationTermination()
        return configuredLifecycleDependencies.endLiveActivitiesForApplicationTermination()
    }

    @objc
    private func sceneWillDeactivate(_ notification: Notification) {
        guard let notifyingScene = notification.object as? UIScene,
              notificationBelongsToConnectedApplicationScene(notification) else { return }
        let otherSceneStates = UIApplication.shared.connectedScenes.compactMap { scene in
            scene === notifyingScene ? nil : scene.activationState
        }
        handleSceneWillDeactivate(connectedOtherSceneStates: otherSceneStates) {
            queueResumableTerminalBackgroundPreparation()
        }
    }

    func handleSceneWillDeactivate(
        connectedOtherSceneStates: [UIScene.ActivationState],
        prepare: () -> Void
    ) {
        guard AppSceneLifecyclePolicy.shouldHandleBackgroundTransition(
            connectedSceneStates: connectedOtherSceneStates
        ) else { return }
        prepare()
    }

    @objc
    private func sceneDidEnterBackground(_ notification: Notification) {
        guard notificationBelongsToConnectedApplicationScene(notification) else { return }
        let sceneStates = UIApplication.shared.connectedScenes.map(\.activationState)
        handleSceneDidEnterBackground(
            connectedSceneStates: sceneStates,
            lock: { configuredAppLockManager.lockIfNeededForBackground() }
        )
        guard AppSceneLifecyclePolicy.shouldHandleBackgroundTransition(
            connectedSceneStates: sceneStates
        ) else { return }

        let taskIdentifier = UIApplication.shared.beginBackgroundTask(
            withName: "Save Resumable Terminal Sessions"
        )
        queueResumableTerminalBackgroundPreparation {
            if taskIdentifier != .invalid {
                UIApplication.shared.endBackgroundTask(taskIdentifier)
            }
        }
    }

    func handleSceneDidEnterBackground(
        connectedSceneStates: [UIScene.ActivationState],
        lock: () -> Void
    ) {
        guard AppSceneLifecyclePolicy.shouldHandleBackgroundTransition(
            connectedSceneStates: connectedSceneStates
        ) else { return }

        lock()
    }

    private func notificationBelongsToConnectedApplicationScene(
        _ notification: Notification
    ) -> Bool {
        guard let notifyingScene = notification.object as? UIScene else { return false }
        return UIApplication.shared.connectedScenes.contains { $0 === notifyingScene }
    }

    private func queueResumableTerminalBackgroundPreparation(
        completion: @escaping @MainActor () -> Void = {}
    ) {
        let tabManager = configuredTabManager
        let previousTask = resumableTerminalLifecycleTask
        resumableTerminalLifecycleTask = Task { @MainActor in
            await previousTask?.value
            await tabManager.transportCoordinator.prepareResumableSessionsForApplicationBackground()
            completion()
        }
    }

    private func queueResumableTerminalResume() {
        let tabManager = configuredTabManager
        let previousTask = resumableTerminalLifecycleTask
        resumableTerminalLifecycleTask = Task { @MainActor in
            await previousTask?.value
            await tabManager.transportCoordinator.resumeResumableSessionsFromApplicationBackground()
        }
    }
}
#endif
