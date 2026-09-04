import XCTest
@testable import VVTerm

@MainActor
private final class TerminalFloatingControlPreferencesRepositorySpy:
    TerminalFloatingControlPreferencesRepository
{
    private let initialPreferences: TerminalFloatingControlPreferences
    private(set) var savedPreferences: [TerminalFloatingControlPreferences] = []

    init(initialPreferences: TerminalFloatingControlPreferences = .defaultValue) {
        self.initialPreferences = initialPreferences
    }

    func load() -> TerminalFloatingControlPreferences {
        initialPreferences
    }

    func save(_ preferences: TerminalFloatingControlPreferences) {
        savedPreferences.append(preferences)
    }
}

@MainActor
final class TerminalFloatingControlPreferencesStoreTests: XCTestCase {
    func testLoadsAndSavesOnlyThroughRepository() {
        let repository = TerminalFloatingControlPreferencesRepositorySpy(
            initialPreferences: .init(horizontalFraction: 0.25, verticalFraction: 0.25)
        )
        let store = TerminalFloatingControlPreferencesStore(repository: repository)

        XCTAssertEqual(store.preferences.horizontalFraction, 0.25)
        XCTAssertEqual(store.preferences.verticalFraction, 0.25)

        store.setStyle(.off)
        store.move(toHorizontalFraction: 2, verticalFraction: -1)

        XCTAssertEqual(repository.savedPreferences.count, 2)
        XCTAssertEqual(store.preferences.style, .off)
        XCTAssertEqual(store.preferences.horizontalFraction, 1)
        XCTAssertEqual(store.preferences.verticalFraction, 0)
    }

    func testActionChangesStayInTheirStyleAndPromotionSwapsActions() {
        let initialPreferences = TerminalFloatingControlPreferences(
            compactActionLayout: .init(
                primaryAction: .voiceInput,
                secondaryActions: [.keyboard, .system(.backspace)]
            )
        )
        let repository = TerminalFloatingControlPreferencesRepositorySpy(
            initialPreferences: initialPreferences
        )
        let store = TerminalFloatingControlPreferencesStore(repository: repository)

        store.replaceSecondaryAction(at: 0, with: .system(.escape), for: .compact)
        store.addSecondaryAction(.system(.tab), for: .compact)
        store.addSecondaryAction(.system(.tab), for: .radial)
        store.promoteToPrimary(.system(.tab), for: .compact)

        XCTAssertEqual(
            store.preferences.compactActionLayout,
            .init(
                primaryAction: .system(.tab),
                secondaryActions: [
                    .system(.escape),
                    .system(.backspace),
                    .voiceInput,
                ]
            )
        )
        XCTAssertEqual(
            store.preferences.radialActionLayout,
            .init(
                primaryAction: .voiceInput,
                secondaryActions: [
                    .system(.backspace),
                    .system(.escape),
                    .keyboard,
                    .system(.tab),
                ]
            )
        )
        XCTAssertEqual(repository.savedPreferences.count, 4)
    }

    func testPrimaryActionMustAlreadyBeSelected() {
        let repository = TerminalFloatingControlPreferencesRepositorySpy()
        let store = TerminalFloatingControlPreferencesStore(repository: repository)

        store.promoteToPrimary(.system(.tab), for: .compact)

        XCTAssertEqual(
            store.preferences.compactActionLayout,
            TerminalFloatingControlPreferences.defaultCompactActionLayout
        )
        XCTAssertTrue(repository.savedPreferences.isEmpty)
    }

    func testResetPositionPreservesStyleAndActions() {
        let initialPreferences = TerminalFloatingControlPreferences(
            style: .radial,
            radialActionLayout: .init(
                primaryAction: .system(.escape),
                secondaryActions: [.voiceInput, .keyboard, .system(.tab)]
            ),
            hiddenSide: .left,
            horizontalFraction: 0.1,
            verticalFraction: 0.2
        )
        let repository = TerminalFloatingControlPreferencesRepositorySpy(
            initialPreferences: initialPreferences
        )
        let store = TerminalFloatingControlPreferencesStore(repository: repository)

        store.resetPosition()

        XCTAssertEqual(store.preferences.style, .radial)
        XCTAssertEqual(
            store.preferences.radialActionLayout,
            initialPreferences.radialActionLayout
        )
        XCTAssertNil(store.preferences.hiddenSide)
        XCTAssertEqual(store.preferences.horizontalFraction, 1)
        XCTAssertEqual(store.preferences.verticalFraction, 1)
        XCTAssertEqual(repository.savedPreferences.count, 1)
    }

    func testShowRestoresAtHiddenSideAndPreservesVerticalPosition() {
        let repository = TerminalFloatingControlPreferencesRepositorySpy(
            initialPreferences: .init(horizontalFraction: 0.37, verticalFraction: 0.2)
        )
        let store = TerminalFloatingControlPreferencesStore(repository: repository)

        store.hide(on: .right, verticalFraction: 0.82)

        XCTAssertEqual(store.preferences.hiddenSide, .right)
        XCTAssertEqual(store.preferences.horizontalFraction, 0.37)
        XCTAssertEqual(store.preferences.verticalFraction, 0.82)

        store.show()

        XCTAssertNil(store.preferences.hiddenSide)
        XCTAssertEqual(store.preferences.horizontalFraction, 1)
        XCTAssertEqual(store.preferences.verticalFraction, 0.82)
        XCTAssertEqual(repository.savedPreferences.count, 2)

        let leftRepository = TerminalFloatingControlPreferencesRepositorySpy(
            initialPreferences: .init(
                hiddenSide: .left,
                horizontalFraction: 1,
                verticalFraction: 0.4
            )
        )
        let leftStore = TerminalFloatingControlPreferencesStore(
            repository: leftRepository
        )

        leftStore.show()

        XCTAssertNil(leftStore.preferences.hiddenSide)
        XCTAssertEqual(leftStore.preferences.horizontalFraction, 0)
        XCTAssertEqual(leftStore.preferences.verticalFraction, 0.4)
        XCTAssertEqual(leftRepository.savedPreferences.count, 1)
    }

    func testActionEditsRejectInvalidIndicesDuplicatesAndCapacityOverflow() {
        let repository = TerminalFloatingControlPreferencesRepositorySpy()
        let store = TerminalFloatingControlPreferencesStore(repository: repository)

        store.replaceSecondaryAction(at: -1, with: .system(.escape), for: .compact)
        store.addSecondaryAction(.keyboard, for: .compact)
        store.addSecondaryAction(.system(.unknown), for: .compact)
        store.removeSecondaryActions(at: IndexSet(integer: 999), for: .compact)
        store.moveSecondaryActions(
            from: IndexSet(integer: 999),
            to: Int.max,
            for: .compact
        )

        XCTAssertEqual(
            store.preferences.compactActionLayout,
            TerminalFloatingControlPreferences.defaultCompactActionLayout
        )
        XCTAssertTrue(repository.savedPreferences.isEmpty)

        store.addSecondaryAction(.system(.escape), for: .compact)
        store.addSecondaryAction(.system(.tab), for: .compact)
        store.addSecondaryAction(.system(.backspace), for: .compact)

        XCTAssertEqual(
            store.preferences.compactActionLayout,
            TerminalFloatingControlPreferences.defaultCompactActionLayout
        )
        XCTAssertTrue(repository.savedPreferences.isEmpty)
    }

    func testMoveClampsDestinationAfterValidatingOffsets() {
        let repository = TerminalFloatingControlPreferencesRepositorySpy(
            initialPreferences: .init(
                compactActionLayout: .init(
                    primaryAction: .voiceInput,
                    secondaryActions: [.keyboard, .system(.escape), .system(.tab)]
                )
            )
        )
        let store = TerminalFloatingControlPreferencesStore(repository: repository)

        store.moveSecondaryActions(
            from: IndexSet(integer: 0),
            to: Int.max,
            for: .compact
        )

        XCTAssertEqual(
            store.preferences.compactActionLayout.secondaryActions,
            [.system(.escape), .system(.tab), .keyboard]
        )
    }
}
