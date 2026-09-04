import Foundation

nonisolated struct TerminalFloatingControlPreferences: Codable, Equatable, Sendable {
    nonisolated enum Style: String, Codable, CaseIterable, Identifiable, Sendable {
        case off
        case compact
        case radial

        var id: String { rawValue }

        var maximumSecondaryActionCount: Int {
            switch self {
            case .off:
                0
            case .compact:
                TerminalFloatingControlPreferences.maximumCompactSecondaryActionCount
            case .radial:
                TerminalFloatingControlPreferences.maximumRadialSecondaryActionCount
            }
        }
    }

    nonisolated enum ActiveStyle: Equatable, Sendable {
        case compact
        case radial

        var storedStyle: Style {
            switch self {
            case .compact: .compact
            case .radial: .radial
            }
        }

        var maximumSecondaryActionCount: Int {
            storedStyle.maximumSecondaryActionCount
        }
    }

    nonisolated enum HiddenSide: String, Codable, Equatable, Sendable {
        case left
        case right

        var restoredHorizontalFraction: Double {
            switch self {
            case .left:
                0
            case .right:
                1
            }
        }
    }

    nonisolated enum Action: Codable, Equatable, Hashable, Identifiable, Sendable {
        case voiceInput
        case keyboard
        case system(TerminalAccessorySystemActionID)

        var id: Self { self }

        static let available: [Self] =
            [.voiceInput, .keyboard]
                + TerminalFloatingControlPreferences.availableSystemActions.map(Self.system)
    }

    nonisolated struct ActionLayout: Codable, Equatable, Sendable {
        var primaryAction: Action
        var secondaryActions: [Action]

        var allActions: [Action] {
            [primaryAction] + secondaryActions
        }
    }

    static let maximumRadialSecondaryActionCount = 7
    static let maximumCompactSecondaryActionCount = 3
    static let defaultHorizontalFraction = 1.0
    static let defaultVerticalFraction = 1.0
    static let defaultCompactActionLayout = ActionLayout(
        primaryAction: .voiceInput,
        secondaryActions: [.system(.backspace), .system(.escape), .keyboard]
    )
    static let defaultRadialActionLayout = ActionLayout(
        primaryAction: .voiceInput,
        secondaryActions: [.system(.backspace), .system(.escape), .keyboard]
    )
    static let defaultValue = TerminalFloatingControlPreferences()

    var style: Style
    var compactActionLayout: ActionLayout
    var radialActionLayout: ActionLayout
    var hiddenSide: HiddenSide?
    var horizontalFraction: Double
    var verticalFraction: Double

    init(
        style: Style = .compact,
        compactActionLayout: ActionLayout = Self.defaultCompactActionLayout,
        radialActionLayout: ActionLayout = Self.defaultRadialActionLayout,
        hiddenSide: HiddenSide? = nil,
        horizontalFraction: Double = Self.defaultHorizontalFraction,
        verticalFraction: Double = Self.defaultVerticalFraction
    ) {
        self.style = style
        self.compactActionLayout = compactActionLayout
        self.radialActionLayout = radialActionLayout
        self.hiddenSide = hiddenSide
        self.horizontalFraction = horizontalFraction
        self.verticalFraction = verticalFraction
    }

    static let availableSystemActions: [TerminalAccessorySystemActionID] =
        TerminalAccessorySystemActionID.allCases.filter {
            $0 != .commandModifier && $0 != .unknown
        }

    func activeStyle(hasProAccess: Bool) -> ActiveStyle? {
        switch style {
        case .off:
            nil
        case .compact:
            .compact
        case .radial:
            hasProAccess ? .radial : .compact
        }
    }

    func actionLayout(for style: Style) -> ActionLayout? {
        switch style {
        case .off:
            nil
        case .compact:
            compactActionLayout
        case .radial:
            radialActionLayout
        }
    }

    func resolvedActionLayout(
        for activeStyle: ActiveStyle,
        hasProAccess: Bool,
        voiceEnabled: Bool
    ) -> ActionLayout {
        let layout: ActionLayout
        if hasProAccess {
            layout = actionLayout(for: activeStyle.storedStyle)
                ?? Self.defaultCompactActionLayout
        } else {
            layout = Self.defaultCompactActionLayout
        }
        guard !voiceEnabled else { return layout }

        let secondaryActions = layout.secondaryActions.filter { $0 != .voiceInput }
        if layout.primaryAction == .voiceInput {
            return ActionLayout(
                primaryAction: .keyboard,
                secondaryActions: secondaryActions.filter { $0 != .keyboard }
            )
        }
        return ActionLayout(
            primaryAction: layout.primaryAction,
            secondaryActions: secondaryActions
        )
    }

    func normalized() -> Self {
        let normalizedHorizontalFraction = horizontalFraction.isFinite
            ? min(max(horizontalFraction, 0), 1)
            : Self.defaultHorizontalFraction
        let normalizedVerticalFraction = verticalFraction.isFinite
            ? min(max(verticalFraction, 0), 1)
            : Self.defaultVerticalFraction

        return Self(
            style: style,
            compactActionLayout: Self.normalized(
                compactActionLayout,
                maximumSecondaryActionCount: Self.maximumCompactSecondaryActionCount
            ),
            radialActionLayout: Self.normalized(
                radialActionLayout,
                maximumSecondaryActionCount: Self.maximumRadialSecondaryActionCount
            ),
            hiddenSide: hiddenSide,
            horizontalFraction: normalizedHorizontalFraction,
            verticalFraction: normalizedVerticalFraction
        )
    }

    private static func normalized(
        _ layout: ActionLayout,
        maximumSecondaryActionCount: Int
    ) -> ActionLayout {
        let primaryAction = isAvailable(layout.primaryAction)
            ? layout.primaryAction
            : Action.voiceInput
        var seenActions: Set<Action> = [primaryAction]
        let secondaryActions = layout.secondaryActions
            .filter { action in
                isAvailable(action) && seenActions.insert(action).inserted
            }
            .prefix(maximumSecondaryActionCount)
        return ActionLayout(
            primaryAction: primaryAction,
            secondaryActions: Array(secondaryActions)
        )
    }

    private static func isAvailable(_ action: Action) -> Bool {
        switch action {
        case .voiceInput, .keyboard:
            true
        case .system(let systemAction):
            availableSystemActions.contains(systemAction)
        }
    }
}
