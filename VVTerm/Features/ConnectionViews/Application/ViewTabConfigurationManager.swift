//
//  ViewTabConfigurationManager.swift
//  VVTerm
//

import Combine
import Foundation
import os.log

@MainActor
final class ViewTabConfigurationManager: ObservableObject {
    static let shared = ViewTabConfigurationManager()

    static let configurationKey = "connectionViewTabConfiguration"

    private enum LegacyKey {
        static let order = "connectionViewTabOrder"
        static let defaultTab = "connectionDefaultViewTab"
        static let showStats = "showStatsTab"
        static let showTerminal = "showTerminalTab"
        static let showFiles = "showFilesTab"

        static let all = [order, defaultTab, showStats, showTerminal, showFiles]
    }

    private let defaults: UserDefaults
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivy.vvterm",
        category: "ViewTabConfigurationManager"
    )

    @Published private(set) var configuration: ConnectionViewTabConfiguration = .default

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadConfiguration()
    }

    var tabOrder: [ConnectionViewTabID] {
        configuration.order
    }

    var currentVisibleTabs: [ConnectionViewTabID] {
        configuration.orderedVisibleTabs
    }

    func moveTab(from source: IndexSet, to destination: Int) {
        guard source.allSatisfy(configuration.order.indices.contains),
              destination >= 0,
              destination <= configuration.order.count else {
            return
        }

        var order = configuration.order
        let movingTabs = source.map { order[$0] }
        for index in source.sorted(by: >) {
            order.remove(at: index)
        }
        let removedBeforeDestination = source.count(in: ..<destination)
        order.insert(
            contentsOf: movingTabs,
            at: destination - removedBeforeDestination
        )
        updateConfiguration(
            ConnectionViewTabConfiguration(
                order: order,
                visibleTabs: configuration.visibleTabs,
                defaultTab: configuration.defaultTab
            )
        )
    }

    func setDefaultTab(_ tabID: ConnectionViewTabID) {
        updateConfiguration(
            ConnectionViewTabConfiguration(
                order: configuration.order,
                visibleTabs: configuration.visibleTabs,
                defaultTab: tabID
            )
        )
    }

    func setVisibility(for tabID: ConnectionViewTabID, isVisible: Bool) {
        var visibleTabs = configuration.visibleTabs

        if isVisible {
            visibleTabs.insert(tabID)
        } else {
            guard visibleTabs.contains(tabID), visibleTabs.count > 1 else { return }
            visibleTabs.remove(tabID)
        }

        updateConfiguration(
            ConnectionViewTabConfiguration(
                order: configuration.order,
                visibleTabs: visibleTabs,
                defaultTab: configuration.defaultTab
            )
        )
    }

    func resetToDefaults() {
        updateConfiguration(.default)
    }

    func effectiveDefaultTab() -> ConnectionViewTabID {
        configuration.effectiveDefaultTab
    }

    func isTabVisible(_ tabID: ConnectionViewTabID) -> Bool {
        configuration.visibleTabs.contains(tabID)
    }

    func effectiveView(for storedView: ConnectionViewTabID?) -> ConnectionViewTabID {
        configuration.effectiveView(for: storedView)
    }

    private func loadConfiguration() {
        if let data = defaults.data(forKey: Self.configurationKey) {
            do {
                configuration = try JSONDecoder().decode(ConnectionViewTabConfiguration.self, from: data)
                removeLegacyConfiguration()
                return
            } catch {
                logger.error("Failed to decode view tab configuration: \(error.localizedDescription)")
            }
        }

        guard LegacyKey.all.contains(where: { defaults.object(forKey: $0) != nil }) else {
            return
        }

        configuration = migratedLegacyConfiguration()
        if saveConfiguration() {
            removeLegacyConfiguration()
        }
    }

    private func migratedLegacyConfiguration() -> ConnectionViewTabConfiguration {
        let order: [ConnectionViewTabID]
        if let data = defaults.data(forKey: LegacyKey.order),
           let storedOrder = try? JSONDecoder().decode([String].self, from: data) {
            order = storedOrder.compactMap(ConnectionViewTabID.init(rawValue:))
        } else {
            order = ConnectionViewTabID.allCases
        }

        let defaultTab = defaults.string(forKey: LegacyKey.defaultTab)
            .flatMap(ConnectionViewTabID.init(rawValue:))
            ?? .stats

        let visibleTabs = Set(ConnectionViewTabID.allCases.filter { tab in
            let key = switch tab {
            case .stats: LegacyKey.showStats
            case .terminal: LegacyKey.showTerminal
            case .files: LegacyKey.showFiles
            }
            return defaults.object(forKey: key) as? Bool ?? true
        })

        return ConnectionViewTabConfiguration(
            order: order,
            visibleTabs: visibleTabs,
            defaultTab: defaultTab
        )
    }

    private func updateConfiguration(_ newConfiguration: ConnectionViewTabConfiguration) {
        guard newConfiguration != configuration else { return }
        configuration = newConfiguration
        saveConfiguration()
    }

    @discardableResult
    private func saveConfiguration() -> Bool {
        do {
            defaults.set(try JSONEncoder().encode(configuration), forKey: Self.configurationKey)
            return true
        } catch {
            logger.error("Failed to encode view tab configuration: \(error.localizedDescription)")
            return false
        }
    }

    private func removeLegacyConfiguration() {
        LegacyKey.all.forEach(defaults.removeObject(forKey:))
    }
}
