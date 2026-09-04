#if os(iOS)
import SwiftUI

struct TerminalFloatingControlPreview: View {
    let preferences: TerminalFloatingControlPreferences
    let hasProAccess: Bool
    let voiceEnabled: Bool
    let onMove: (Double, Double) -> Void
    let onHide: (TerminalFloatingControlPreferences.HiddenSide, Double) -> Void
    let onShow: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragState = DragState.idle

    private let controlDragMinimumDistance: CGFloat = 10
    private let edgeDragMinimumDistance: CGFloat = 4

    private enum DragState: Equatable {
        case idle
        case control(CGSize)
        case edge(CGSize)

        var controlTranslation: CGSize {
            if case .control(let translation) = self { return translation }
            return .zero
        }

        var edgeTranslation: CGSize {
            if case .edge(let translation) = self { return translation }
            return .zero
        }

        var isDraggingControl: Bool {
            if case .control = self { return true }
            return false
        }
    }

    private var activeStyle: TerminalFloatingControlPreferences.ActiveStyle? {
        preferences.activeStyle(hasProAccess: hasProAccess)
    }

    private var actionLayout: TerminalFloatingControlPreferences.ActionLayout {
        preferences.resolvedActionLayout(
            for: activeStyle ?? .compact,
            hasProAccess: hasProAccess,
            voiceEnabled: voiceEnabled
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                terminalBackdrop

                if let activeStyle {
                    if let hiddenSide = preferences.hiddenSide {
                        draggableEdgeHandle(for: hiddenSide, in: proxy)
                            .transition(.opacity)
                    } else {
                        let bounds = anchorBounds(for: activeStyle, in: proxy)
                        let storedAnchor = previewAnchor(
                            for: activeStyle,
                            in: proxy,
                            bounds: bounds
                        )
                        let currentAnchor = displayedAnchor(
                            from: storedAnchor,
                            bounds: bounds,
                            in: proxy
                        )
                        let placement = TerminalFloatingControlLayout.placement(
                            for: activeStyle,
                            anchorCenter: currentAnchor,
                            secondaryActionCount: actionLayout.secondaryActions.count,
                            containerSize: proxy.size,
                            safeAreaInsets: proxy.safeAreaInsets
                        )

                        previewControl(
                            style: activeStyle,
                            placement: placement
                        )
                        .frame(
                            width: placement.frame.width,
                            height: placement.frame.height
                        )
                        .simultaneousGesture(
                            controlDragGesture(
                                for: activeStyle,
                                in: proxy,
                                from: storedAnchor
                            )
                        )
                        .position(placement.frameCenter)
                        .transition(.opacity)
                    }
                } else {
                    Text("No floating control")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 236)
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Control preview")
        .accessibilityValue(
            activeStyle?.storedStyle.displayTitle
                ?? TerminalFloatingControlPreferences.Style.off.displayTitle
        )
        .accessibilityIdentifier("vvterm.settings.floatingInputControl.preview")
        .animation(controlAnimation, value: preferences.hiddenSide)
    }

    private var controlAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.1)
            : .spring(response: 0.3, dampingFraction: 0.86)
    }

    private var terminalBackdrop: some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: .systemBackground)

            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "$ ssh server")
                Text(verbatim: "server:~ $ _")
                Text(verbatim: "────────────────")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary.opacity(0.45))
            .padding(16)
        }
    }

    @ViewBuilder
    private func previewControl(
        style: TerminalFloatingControlPreferences.ActiveStyle,
        placement: TerminalFloatingControlLayout.Placement
    ) -> some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: TerminalFloatingControlLayout.buttonSpacing) {
                previewControlLayout(
                    style: style,
                    placement: placement
                )
            }
        } else {
            previewControlLayout(
                style: style,
                placement: placement
            )
        }
    }

    private func previewControlLayout(
        style: TerminalFloatingControlPreferences.ActiveStyle,
        placement: TerminalFloatingControlLayout.Placement
    ) -> some View {
        ZStack {
            previewButton(
                for: actionLayout.primaryAction,
                size: TerminalFloatingControlLayout.mainButtonSize(for: style),
                isPrimary: true
            )
            .position(placement.localCenter(for: placement.mainCenter))

            ForEach(
                Array(
                    actionLayout.secondaryActions
                        .prefix(placement.secondaryCenters.count)
                        .enumerated()
                ),
                id: \.element
            ) { index, action in
                previewButton(
                    for: action,
                    size: TerminalFloatingControlLayout.radialSecondaryButtonSize,
                    isPrimary: false
                )
                .position(placement.localCenter(for: placement.secondaryCenters[index]))
            }
        }
    }

    private func previewButton(
        for action: TerminalFloatingControlPreferences.Action,
        size: CGFloat,
        isPrimary: Bool
    ) -> some View {
        TerminalFloatingControlButton(
            content: action.iconName.map(TerminalFloatingControlButton.Content.systemImage)
                ?? .text(action.shortTitle),
            accessibilityLabel: action.displayTitle,
            accessibilityIdentifier: previewButtonIdentifier(for: action),
            size: size,
            tint: isPrimary ? .accentColor : nil,
            isEnabled: true,
            isInteractive: false,
            action: {}
        )
        .accessibilityHidden(true)
    }

    private func previewButtonIdentifier(
        for action: TerminalFloatingControlPreferences.Action
    ) -> String {
        let actionID: String
        switch action {
        case .voiceInput:
            actionID = "voiceInput"
        case .keyboard:
            actionID = "keyboard"
        case .system(let systemAction):
            actionID = "system.\(systemAction.rawValue)"
        }
        return "vvterm.settings.floatingInputControl.previewButton.\(actionID)"
    }

    private func draggableEdgeHandle(
        for side: TerminalFloatingControlPreferences.HiddenSide,
        in proxy: GeometryProxy
    ) -> some View {
        TerminalFloatingControlEdgeHandle(
            side: side,
            accessibilityIdentifier: "vvterm.settings.floatingInputControl.previewEdgeHandle",
            action: onShow
        )
        .position(
            TerminalFloatingControlLayout.edgeHandleDragCenter(
                for: side,
                verticalFraction: preferences.verticalFraction,
                translation: dragState.edgeTranslation,
                containerSize: proxy.size,
                safeAreaInsets: proxy.safeAreaInsets
            )
        )
        .highPriorityGesture(edgeHandleDragGesture(for: side, in: proxy))
    }

    private func anchorBounds(
        for style: TerminalFloatingControlPreferences.ActiveStyle,
        in proxy: GeometryProxy
    ) -> CGRect {
        TerminalFloatingControlLayout.anchorBounds(
            containerSize: proxy.size,
            safeAreaInsets: proxy.safeAreaInsets,
            mainButtonSize: TerminalFloatingControlLayout.mainButtonSize(for: style)
        )
    }

    private func previewAnchor(
        for style: TerminalFloatingControlPreferences.ActiveStyle,
        in proxy: GeometryProxy,
        bounds: CGRect
    ) -> CGPoint {
        let preferredAnchor = TerminalFloatingControlLayout.center(
            horizontalFraction: preferences.horizontalFraction,
            verticalFraction: preferences.verticalFraction,
            in: bounds
        )
        return TerminalFloatingControlLayout.previewAnchor(
            for: style,
            preferredCenter: preferredAnchor,
            secondaryActionCount: actionLayout.secondaryActions.count,
            containerSize: proxy.size,
            safeAreaInsets: proxy.safeAreaInsets
        )
    }

    private func displayedAnchor(
        from storedAnchor: CGPoint,
        bounds: CGRect,
        in proxy: GeometryProxy
    ) -> CGPoint {
        let translation = dragState.controlTranslation
        let proposedCenter = CGPoint(
            x: storedAnchor.x + translation.width,
            y: storedAnchor.y + translation.height
        )
        if dragState.isDraggingControl {
            return TerminalFloatingControlLayout.edgeDragCenter(
                proposedCenter,
                containerSize: proxy.size,
                safeAreaInsets: proxy.safeAreaInsets,
                anchorBounds: bounds
            )
        }
        return TerminalFloatingControlLayout.clampedCenter(proposedCenter, in: bounds)
    }

    private func controlDragGesture(
        for style: TerminalFloatingControlPreferences.ActiveStyle,
        in proxy: GeometryProxy,
        from storedAnchor: CGPoint
    ) -> some Gesture {
        DragGesture(minimumDistance: controlDragMinimumDistance, coordinateSpace: .global)
            .updating($dragState) { value, state, _ in
                let bounds = anchorBounds(for: style, in: proxy)
                let proposedCenter = CGPoint(
                    x: storedAnchor.x + value.translation.width,
                    y: storedAnchor.y + value.translation.height
                )
                let center = TerminalFloatingControlLayout.edgeDragCenter(
                    proposedCenter,
                    containerSize: proxy.size,
                    safeAreaInsets: proxy.safeAreaInsets,
                    anchorBounds: bounds
                )
                state = .control(
                    CGSize(
                        width: center.x - storedAnchor.x,
                        height: center.y - storedAnchor.y
                    )
                )
            }
            .onEnded { value in
                let bounds = anchorBounds(for: style, in: proxy)
                let proposedCenter = CGPoint(
                    x: storedAnchor.x + value.translation.width,
                    y: storedAnchor.y + value.translation.height
                )
                let predictedEndCenter = CGPoint(
                    x: storedAnchor.x + value.predictedEndTranslation.width,
                    y: storedAnchor.y + value.predictedEndTranslation.height
                )
                let center = TerminalFloatingControlLayout.clampedCenter(
                    proposedCenter,
                    in: bounds
                )
                let position = TerminalFloatingControlLayout.normalizedPosition(
                    for: center,
                    in: bounds
                )
                if let side = TerminalFloatingControlLayout.hiddenSide(
                    for: proposedCenter,
                    predictedEndCenter: predictedEndCenter,
                    containerSize: proxy.size,
                    safeAreaInsets: proxy.safeAreaInsets
                ) {
                    onHide(side, position.verticalFraction)
                } else {
                    onMove(position.horizontalFraction, position.verticalFraction)
                }
            }
    }

    private func edgeHandleDragGesture(
        for side: TerminalFloatingControlPreferences.HiddenSide,
        in proxy: GeometryProxy
    ) -> some Gesture {
        DragGesture(minimumDistance: edgeDragMinimumDistance, coordinateSpace: .global)
            .updating($dragState) { value, state, _ in
                state = .edge(value.translation)
            }
            .onEnded { value in
                guard let style = activeStyle else { return }
                switch TerminalFloatingControlLayout.edgeHandleRelease(
                    for: side,
                    verticalFraction: preferences.verticalFraction,
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    style: style,
                    containerSize: proxy.size,
                    safeAreaInsets: proxy.safeAreaInsets
                ) {
                case .hidden(let verticalFraction):
                    onHide(side, verticalFraction)
                case .visible(let position):
                    onMove(position.horizontalFraction, position.verticalFraction)
                }
            }
    }
}
#endif
