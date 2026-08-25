import Foundation

@MainActor
enum TerminalRemoteSessionLiveComposition {
    static func makeConfiguration(
        defaults: UserDefaults,
        serverManager: ServerManager,
        deviceID: String,
        themeStyle: @escaping @MainActor () -> RemoteSessionThemeStyle
    ) -> TerminalRemoteSessionConfiguration {
        migrateLegacyDefaults(in: defaults)
        return TerminalRemoteSessionConfiguration(
            deviceID: deviceID,
            enabledByDefault: {
                guard defaults.object(
                    forKey: TerminalRemoteSessionDefaults.enabledKey
                ) != nil else {
                    return true
                }
                return defaults.bool(forKey: TerminalRemoteSessionDefaults.enabledKey)
            },
            backendIdentifierByDefault: {
                defaults.string(forKey: TerminalRemoteSessionDefaults.backendIdentifierKey)
                    .map(RemoteSessionBackendIdentifier.init(rawValue:)) ?? .tmux
            },
            startupBehaviorByDefault: {
                guard let rawValue = defaults.string(
                    forKey: TerminalRemoteSessionDefaults.startupBehaviorKey
                ) else {
                    return .ask
                }
                return RemoteSessionStartupBehavior(persistedRawValue: rawValue) ?? .ask
            },
            serverSettings: { serverId in
                serverManager.servers
                    .first(where: { $0.id == serverId })
                    .map {
                        TerminalRemoteSessionConfiguration.ServerSettings(
                            name: $0.name,
                            enabledOverride: $0.remoteSessionEnabledOverride,
                            backendIdentifier: $0.remoteSessionBackendIdentifier,
                            startupBehaviorOverride: $0.remoteSessionStartupBehaviorOverride,
                            startupAction: $0.remoteShellStartupAction
                        )
                    }
            },
            themeStyle: themeStyle
        )
    }

    private static func migrateLegacyDefaults(in defaults: UserDefaults) {
        if defaults.object(forKey: TerminalRemoteSessionDefaults.enabledKey) == nil,
           defaults.object(forKey: TerminalRemoteSessionDefaults.legacyEnabledKey) != nil {
            defaults.set(
                defaults.bool(forKey: TerminalRemoteSessionDefaults.legacyEnabledKey),
                forKey: TerminalRemoteSessionDefaults.enabledKey
            )
        }
        if defaults.string(forKey: TerminalRemoteSessionDefaults.startupBehaviorKey) == nil,
           let legacyRawValue = defaults.string(
               forKey: TerminalRemoteSessionDefaults.legacyStartupBehaviorKey
           ),
           let behavior = RemoteSessionStartupBehavior(persistedRawValue: legacyRawValue) {
            defaults.set(
                behavior.rawValue,
                forKey: TerminalRemoteSessionDefaults.startupBehaviorKey
            )
        }
    }

    nonisolated static func themeStyle(for storedName: String?) -> RemoteSessionThemeStyle {
        let name = (try? TerminalThemeValidator.validateAndNormalizeThemeName(
            storedName ?? "Aizen Dark"
        )) ?? "Aizen Dark"
        return RemoteSessionThemeStyle(
            name: name,
            modeStyle: ThemeColorParser.tmuxModeStyle(for: name)
        )
    }
}

extension RemoteSessionClient: TerminalRemoteSessionServicing {}
