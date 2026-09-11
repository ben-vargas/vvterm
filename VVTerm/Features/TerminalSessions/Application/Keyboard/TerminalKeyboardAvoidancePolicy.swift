import CoreGraphics

enum TerminalKeyboardAvoidancePolicy {
    nonisolated enum KeyboardGeometry: Equatable {
        case hidden
        case docked(frame: CGRect)
        case floating(frame: CGRect)
    }

    nonisolated struct Layout: Equatable {
        var bottomChromeInset: CGFloat = 0
        var bottomInset: CGFloat
        var verticalOffset: CGFloat
        var preservesTerminalSurfaceSize: Bool

        static let unobstructed = Layout(
            bottomInset: 0,
            verticalOffset: 0,
            preservesTerminalSurfaceSize: false
        )
    }

    nonisolated static let defaultCursorClearance: CGFloat = 12
    nonisolated static let minimumVisibleHeight: CGFloat = 1

    nonisolated static func resolvedGeometry(
        screenFrame: CGRect,
        terminalFrame: CGRect,
        keyboardFrame: CGRect?
    ) -> KeyboardGeometry {
        guard let keyboardFrame,
              isValid(screenFrame),
              isValid(terminalFrame),
              isValid(keyboardFrame),
              terminalFrame.intersects(keyboardFrame)
        else {
            return .hidden
        }

        let attachesToBottom = keyboardFrame.maxY >= screenFrame.maxY - 1
        let spansScreenWidth = keyboardFrame.width >= screenFrame.width * 0.8
        return attachesToBottom && spansScreenWidth
            ? .docked(frame: keyboardFrame)
            : .floating(frame: keyboardFrame)
    }

    nonisolated static func verticalOffset(
        terminalFrame: CGRect,
        cursorFrame: CGRect,
        keyboardFrame: CGRect?,
        cursorClearance: CGFloat = defaultCursorClearance
    ) -> CGFloat {
        guard let keyboardFrame,
              isValid(keyboardFrame),
              isValid(terminalFrame),
              isValid(cursorFrame),
              cursorClearance.isFinite,
              terminalFrame.intersects(keyboardFrame)
        else {
            return 0
        }

        let cursorOverlapsKeyboardHorizontally = cursorFrame.maxX > keyboardFrame.minX
            && cursorFrame.minX < keyboardFrame.maxX
        guard cursorOverlapsKeyboardHorizontally else { return 0 }

        let requiredLift = cursorFrame.maxY + max(cursorClearance, 0) - keyboardFrame.minY
        guard requiredLift > 0 else { return 0 }

        let maximumLift = max(terminalFrame.height - minimumVisibleHeight, 0)
        guard maximumLift > 0 else { return 0 }

        return -min(requiredLift, maximumLift)
    }

    nonisolated static func layout(
        preservesTerminalSize: Bool,
        geometry: KeyboardGeometry,
        terminalFrame: CGRect,
        cursorFrame: CGRect,
        accessoryFrame: CGRect? = nil
    ) -> Layout {
        guard isValid(terminalFrame) else { return .unobstructed }
        let maximumInset = max(terminalFrame.height - minimumVisibleHeight, 0)
        let accessoryInset = bottomAccessoryInset(
            terminalFrame: terminalFrame,
            accessoryFrame: accessoryFrame
        )
        var inset = accessoryInset
        var offset: CGFloat = 0
        if case let .docked(frame) = geometry, isValid(frame) {
            inset = max(inset, terminalFrame.maxY - max(frame.minY, terminalFrame.minY))
            if preservesTerminalSize {
                // Only docked obstruction moves content. A floating keyboard
                // remains user-positioned, even when it covers the cursor.
                let obstruction = CGRect(
                    x: terminalFrame.minX,
                    y: terminalFrame.maxY - min(max(inset, 0), maximumInset),
                    width: terminalFrame.width,
                    height: min(max(inset, 0), maximumInset)
                )
                offset = verticalOffset(
                    terminalFrame: terminalFrame,
                    cursorFrame: cursorFrame,
                    keyboardFrame: obstruction
                )
            }
        }
        return Layout(
            bottomInset: min(max(inset, 0), maximumInset),
            verticalOffset: offset,
            preservesTerminalSurfaceSize: preservesTerminalSize
        )
    }

    nonisolated static func isValid(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite
            && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
            && frame.maxX.isFinite && frame.maxY.isFinite
    }

    private nonisolated static func bottomAccessoryInset(
        terminalFrame: CGRect,
        accessoryFrame: CGRect?
    ) -> CGFloat {
        guard let accessoryFrame,
              isValid(terminalFrame),
              isValid(accessoryFrame),
              accessoryFrame.maxY >= terminalFrame.maxY - 1 else {
            return 0
        }

        let horizontalOverlap = min(terminalFrame.maxX, accessoryFrame.maxX)
            - max(terminalFrame.minX, accessoryFrame.minX)
        guard horizontalOverlap >= terminalFrame.width * 0.8 else { return 0 }

        return min(
            max(terminalFrame.maxY - max(accessoryFrame.minY, terminalFrame.minY), 0),
            max(terminalFrame.height, 0)
        )
    }
}
