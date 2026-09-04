import Combine
import Foundation

@MainActor
final class TerminalFloatingControlPreferencesStore: ObservableObject {
    @Published private(set) var preferences: TerminalFloatingControlPreferences

    private let repository: any TerminalFloatingControlPreferencesRepository

    init(repository: any TerminalFloatingControlPreferencesRepository) {
        self.repository = repository
        self.preferences = repository.load().normalized()
    }

    func setStyle(_ style: TerminalFloatingControlPreferences.Style) {
        update { $0.style = style }
    }

    func promoteToPrimary(
        _ action: TerminalFloatingControlPreferences.Action,
        for style: TerminalFloatingControlPreferences.Style
    ) {
        updateLayout(for: style) { layout in
            guard action != layout.primaryAction,
                  let index = layout.secondaryActions.firstIndex(of: action) else {
                return
            }
            layout.secondaryActions[index] = layout.primaryAction
            layout.primaryAction = action
        }
    }

    func replaceSecondaryAction(
        at index: Int,
        with action: TerminalFloatingControlPreferences.Action,
        for style: TerminalFloatingControlPreferences.Style
    ) {
        updateLayout(for: style) { layout in
            guard layout.secondaryActions.indices.contains(index) else { return }
            guard !layout.allActions.contains(action)
                    || layout.secondaryActions[index] == action else { return }
            layout.secondaryActions[index] = action
        }
    }

    func addSecondaryAction(
        _ action: TerminalFloatingControlPreferences.Action,
        for style: TerminalFloatingControlPreferences.Style
    ) {
        updateLayout(for: style) { layout in
            guard layout.secondaryActions.count < style.maximumSecondaryActionCount,
                  !layout.allActions.contains(action) else { return }
            layout.secondaryActions.append(action)
        }
    }

    func removeSecondaryActions(
        at offsets: IndexSet,
        for style: TerminalFloatingControlPreferences.Style
    ) {
        updateLayout(for: style) { layout in
            let validOffsets = offsets.filter(layout.secondaryActions.indices.contains)
            for index in validOffsets.sorted(by: >) {
                layout.secondaryActions.remove(at: index)
            }
        }
    }

    func moveSecondaryActions(
        from offsets: IndexSet,
        to destination: Int,
        for style: TerminalFloatingControlPreferences.Style
    ) {
        updateLayout(for: style) { layout in
            let validOffsets = offsets
                .filter(layout.secondaryActions.indices.contains)
                .sorted()
            guard !validOffsets.isEmpty else { return }

            let movedActions = validOffsets.map { layout.secondaryActions[$0] }
            for index in validOffsets.reversed() {
                layout.secondaryActions.remove(at: index)
            }

            let removedBeforeDestination = validOffsets.lazy
                .filter { $0 < destination }
                .count
            let adjustedDestination = destination > removedBeforeDestination
                ? destination - removedBeforeDestination
                : 0
            let insertionIndex = min(
                max(adjustedDestination, 0),
                layout.secondaryActions.count
            )
            layout.secondaryActions.insert(contentsOf: movedActions, at: insertionIndex)
        }
    }

    func move(
        toHorizontalFraction horizontalFraction: Double,
        verticalFraction: Double
    ) {
        update {
            $0.hiddenSide = nil
            $0.horizontalFraction = horizontalFraction
            $0.verticalFraction = verticalFraction
        }
    }

    func hide(
        on side: TerminalFloatingControlPreferences.HiddenSide,
        verticalFraction: Double
    ) {
        update {
            $0.hiddenSide = side
            $0.verticalFraction = verticalFraction
        }
    }

    func show() {
        update {
            if let hiddenSide = $0.hiddenSide {
                $0.horizontalFraction = hiddenSide.restoredHorizontalFraction
            }
            $0.hiddenSide = nil
        }
    }

    func resetPosition() {
        update {
            $0.hiddenSide = nil
            $0.horizontalFraction =
                TerminalFloatingControlPreferences.defaultHorizontalFraction
            $0.verticalFraction =
                TerminalFloatingControlPreferences.defaultVerticalFraction
        }
    }

    private func updateLayout(
        for style: TerminalFloatingControlPreferences.Style,
        _ mutate: (inout TerminalFloatingControlPreferences.ActionLayout) -> Void
    ) {
        update { preferences in
            guard var layout = preferences.actionLayout(for: style) else { return }
            mutate(&layout)
            switch style {
            case .off:
                break
            case .compact:
                preferences.compactActionLayout = layout
            case .radial:
                preferences.radialActionLayout = layout
            }
        }
    }

    private func update(
        _ mutate: (inout TerminalFloatingControlPreferences) -> Void
    ) {
        var nextPreferences = preferences
        mutate(&nextPreferences)
        nextPreferences = nextPreferences.normalized()
        guard nextPreferences != preferences else { return }
        preferences = nextPreferences
        repository.save(nextPreferences)
    }
}
