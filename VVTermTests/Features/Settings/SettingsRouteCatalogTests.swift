import Foundation
import Testing
@testable import VVTerm

@Suite("Settings route catalog")
struct SettingsRouteCatalogTests {
    @Test("Catalog follows the approved grouped order")
    func approvedGroupedOrder() {
        #expect(SettingsRoute.defaultRoute == .appearanceAndLanguage)
        #expect(SettingsRoute.defaultRoute != .pro)
        #expect(SettingsRouteCatalog.groups == [
            .account,
            .app,
            .terminal,
            .dataAndSecurity,
            .voice,
            .support,
        ])
        #expect(SettingsRouteCatalog.routes(in: .account) == [.pro])
        #expect(SettingsRouteCatalog.routes(in: .app) == [
            .appearanceAndLanguage,
            .navigationAndStats,
            .privacyAndAppLock,
        ])
        #expect(SettingsRouteCatalog.routes(in: .terminal) == [
            .terminalAppearance,
            .keyboardAndInput,
            .sessionsAndConnections,
            .clipboardAndPaste,
        ])
        #expect(SettingsRouteCatalog.routes(in: .dataAndSecurity) == [
            .sshKeys,
            .trustedHosts,
            .iCloudSync,
        ])
        #expect(SettingsRouteCatalog.routes(in: .voice) == [.transcription])
        #expect(SettingsRouteCatalog.routes(in: .support) == [.aboutAndSupport])
    }

    @Test("Search finds page titles, labels, and common terms", arguments: [
        ("cursor", SettingsRoute.terminalAppearance),
        ("tmux", SettingsRoute.sessionsAndConnections),
        ("analytics", SettingsRoute.privacyAndAppLock),
        ("fingerprint", SettingsRoute.trustedHosts),
        ("keyboard", SettingsRoute.keyboardAndInput),
    ])
    func search(query: String, expectedRoute: SettingsRoute) {
        #expect(SettingsRouteCatalog.routes(matching: query).contains(expectedRoute))
    }

    @Test("Empty search returns every route")
    func emptySearch() {
        #expect(SettingsRouteCatalog.routes(matching: "  ") == SettingsRoute.allCases)
    }
}

@Suite("Settings route persistence")
struct SettingsRoutePersistenceTests {
    @Test("Selection round-trips through the existing defaults store")
    func selectionRoundTrip() throws {
        let suiteName = "SettingsRoutePersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SettingsRoutePersistence.load(from: defaults) == .appearanceAndLanguage)

        SettingsRoutePersistence.save(.clipboardAndPaste, to: defaults)

        #expect(SettingsRoutePersistence.load(from: defaults) == .clipboardAndPaste)
    }

    @Test("Unknown persisted values use the stable default page")
    func unknownValueFallback() {
        #expect(SettingsRoutePersistence.route(for: "removed-route") == .appearanceAndLanguage)
    }
}
