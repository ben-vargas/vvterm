#if os(iOS)
import SwiftUI

nonisolated enum TerminalFloatingControlLayout {
    nonisolated struct Position: Equatable, Sendable {
        let horizontalFraction: Double
        let verticalFraction: Double
    }

    nonisolated struct Placement: Equatable, Sendable {
        let frame: CGRect
        let mainCenter: CGPoint
        let secondaryCenters: [CGPoint]

        var frameCenter: CGPoint {
            CGPoint(x: frame.midX, y: frame.midY)
        }

        func localCenter(for center: CGPoint) -> CGPoint {
            CGPoint(x: center.x - frame.minX, y: center.y - frame.minY)
        }
    }

    nonisolated enum EdgeHandleRelease: Equatable, Sendable {
        case hidden(verticalFraction: Double)
        case visible(Position)
    }

    static let compactButtonSize: CGFloat = 44
    static let radialMainButtonSize: CGFloat = 68
    static let radialSecondaryButtonSize: CGFloat = 44
    static let radialOrbitRadius: CGFloat = 70
    static let buttonSpacing: CGFloat = 8
    static let controlEdgeMargin: CGFloat = 24
    static let safeMargin: CGFloat = 12
    static let edgeHandleSize = CGSize(width: 44, height: 52)
    static let edgeHandleVisualSize = CGSize(width: 32, height: 48)
    static let edgeHideActivationInset: CGFloat = 8
    static let voiceStatusMaximumWidth: CGFloat = 300
    static let voiceStatusEstimatedHeight: CGFloat = 112
    static let voiceStatusGap: CGFloat = 12

    private static let maximumLayoutDimension: CGFloat = 1_000_000

    private enum VerticalSide {
        case top
        case bottom
    }

    private enum RadialRegion {
        case center
        case horizontal(TerminalFloatingControlPreferences.HiddenSide)
        case vertical(VerticalSide)
        case corner(TerminalFloatingControlPreferences.HiddenSide, VerticalSide)
    }

    static func mainButtonSize(
        for style: TerminalFloatingControlPreferences.ActiveStyle
    ) -> CGFloat {
        switch style {
        case .compact:
            compactButtonSize
        case .radial:
            radialMainButtonSize
        }
    }

    static func anchorBounds(
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets,
        mainButtonSize: CGFloat
    ) -> CGRect {
        let primaryInsets = EdgeInsets(
            top: safeAreaInsets.top,
            leading: safeAreaInsets.leading,
            bottom: 0,
            trailing: safeAreaInsets.trailing
        )
        return centerBounds(
            containerSize: containerSize,
            safeAreaInsets: primaryInsets,
            itemSize: CGSize(width: mainButtonSize, height: mainButtonSize),
            margin: controlEdgeMargin
        )
    }

    static func placement(
        for style: TerminalFloatingControlPreferences.ActiveStyle,
        anchorCenter: CGPoint,
        secondaryActionCount: Int,
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> Placement {
        let count = min(
            max(secondaryActionCount, 0),
            style.maximumSecondaryActionCount
        )
        let secondaryCenters: [CGPoint]
        let mainSize = mainButtonSize(for: style)

        switch style {
        case .compact:
            secondaryCenters = compactSecondaryCenters(
                anchorCenter: anchorCenter,
                count: count,
                containerSize: containerSize,
                safeAreaInsets: safeAreaInsets
            )
        case .radial:
            secondaryCenters = radialSecondaryCenters(
                anchorCenter: anchorCenter,
                count: count,
                containerSize: containerSize,
                safeAreaInsets: safeAreaInsets
            )
        }

        return Placement(
            frame: contentFrame(
                mainCenter: anchorCenter,
                mainSize: mainSize,
                secondaryCenters: secondaryCenters,
                secondarySize: radialSecondaryButtonSize
            ),
            mainCenter: anchorCenter,
            secondaryCenters: secondaryCenters
        )
    }

    static func previewAnchor(
        for style: TerminalFloatingControlPreferences.ActiveStyle,
        preferredCenter: CGPoint,
        secondaryActionCount: Int,
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> CGPoint {
        let bounds = anchorBounds(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets,
            mainButtonSize: mainButtonSize(for: style)
        )
        let preferredCenter = clampedCenter(preferredCenter, in: bounds)
        guard style == .compact else { return preferredCenter }

        let count = min(
            max(secondaryActionCount, 0),
            style.maximumSecondaryActionCount
        )
        guard count > 0 else { return preferredCenter }

        let actionBounds = secondaryActionBounds(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        let requiredDistance = CGFloat(count) * (compactButtonSize + buttonSpacing)
        let belowMaximum = actionBounds.maxY - requiredDistance
        let aboveMinimum = actionBounds.minY + requiredDistance
        let belowY = belowMaximum >= actionBounds.minY
            ? min(preferredCenter.y, belowMaximum)
            : nil
        let aboveY = aboveMinimum <= actionBounds.maxY
            ? max(preferredCenter.y, aboveMinimum)
            : nil

        let fittedY: CGFloat
        switch (belowY, aboveY) {
        case (.some(let belowY), .some(let aboveY)):
            fittedY = abs(preferredCenter.y - belowY)
                <= abs(preferredCenter.y - aboveY)
                ? belowY
                : aboveY
        case (.some(let belowY), .none):
            fittedY = belowY
        case (.none, .some(let aboveY)):
            fittedY = aboveY
        case (.none, .none):
            return preferredCenter
        }

        return clampedCenter(
            CGPoint(x: preferredCenter.x, y: fittedY),
            in: bounds
        )
    }

    static func center(
        horizontalFraction: Double,
        verticalFraction: Double,
        in bounds: CGRect
    ) -> CGPoint {
        CGPoint(
            x: bounds.minX
                + bounds.width * CGFloat(normalizedFraction(
                    horizontalFraction,
                    fallback: TerminalFloatingControlPreferences.defaultHorizontalFraction
                )),
            y: bounds.minY
                + bounds.height * CGFloat(normalizedFraction(
                    verticalFraction,
                    fallback: TerminalFloatingControlPreferences.defaultVerticalFraction
                ))
        )
    }

    static func clampedCenter(_ center: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: clampedCoordinate(center.x, in: bounds.minX ... bounds.maxX),
            y: clampedCoordinate(center.y, in: bounds.minY ... bounds.maxY)
        )
    }

    static func edgeDragCenter(
        _ center: CGPoint,
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets,
        anchorBounds: CGRect
    ) -> CGPoint {
        let visibleFrame = visibleFrame(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        return CGPoint(
            x: clampedCoordinate(center.x, in: visibleFrame.minX ... visibleFrame.maxX),
            y: clampedCoordinate(center.y, in: anchorBounds.minY ... anchorBounds.maxY)
        )
    }

    static func hiddenSide(
        for center: CGPoint,
        predictedEndCenter: CGPoint? = nil,
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> TerminalFloatingControlPreferences.HiddenSide? {
        guard center.x.isFinite else { return nil }
        let visibleFrame = visibleFrame(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        if center.x <= visibleFrame.minX + edgeHideActivationInset {
            return .left
        }
        if center.x >= visibleFrame.maxX - edgeHideActivationInset {
            return .right
        }

        guard let predictedEndCenter, predictedEndCenter.x.isFinite else {
            return nil
        }
        let leftActivationX = visibleFrame.minX + edgeHideActivationInset
        if center.x <= leftActivationX + edgeHandleSize.width,
           predictedEndCenter.x < center.x,
           predictedEndCenter.x <= leftActivationX {
            return .left
        }
        let rightActivationX = visibleFrame.maxX - edgeHideActivationInset
        if center.x >= rightActivationX - edgeHandleSize.width,
           predictedEndCenter.x > center.x,
           predictedEndCenter.x >= rightActivationX {
            return .right
        }
        return nil
    }

    static func normalizedPosition(for center: CGPoint, in bounds: CGRect) -> Position {
        let horizontalFraction = bounds.width > 0 && center.x.isFinite
            ? Double((center.x - bounds.minX) / bounds.width)
            : TerminalFloatingControlPreferences.defaultHorizontalFraction
        let verticalFraction = bounds.height > 0 && center.y.isFinite
            ? Double((center.y - bounds.minY) / bounds.height)
            : TerminalFloatingControlPreferences.defaultVerticalFraction
        return Position(
            horizontalFraction: normalizedFraction(
                horizontalFraction,
                fallback: TerminalFloatingControlPreferences.defaultHorizontalFraction
            ),
            verticalFraction: normalizedFraction(
                verticalFraction,
                fallback: TerminalFloatingControlPreferences.defaultVerticalFraction
            )
        )
    }

    static func edgeHandleCenter(
        for side: TerminalFloatingControlPreferences.HiddenSide,
        verticalFraction: Double,
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> CGPoint {
        let bounds = edgeHandleBounds(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        let x = side == .left
            ? bounds.minX
            : bounds.maxX
        return CGPoint(
            x: x,
            y: bounds.minY
                + bounds.height
                * CGFloat(normalizedFraction(
                    verticalFraction,
                    fallback: TerminalFloatingControlPreferences.defaultVerticalFraction
                ))
        )
    }

    static func edgeHandleDragCenter(
        for side: TerminalFloatingControlPreferences.HiddenSide,
        verticalFraction: Double,
        translation: CGSize,
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> CGPoint {
        let bounds = edgeHandleBounds(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        let start = edgeHandleCenter(
            for: side,
            verticalFraction: verticalFraction,
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        let horizontalRange = side == .left
            ? start.x ... bounds.maxX
            : bounds.minX ... start.x
        return CGPoint(
            x: clampedOffset(
                translation.width,
                from: start.x,
                in: horizontalRange
            ),
            y: clampedOffset(
                translation.height,
                from: start.y,
                in: bounds.minY ... bounds.maxY
            )
        )
    }

    static func edgeHandleRelease(
        for side: TerminalFloatingControlPreferences.HiddenSide,
        verticalFraction: Double,
        translation: CGSize,
        predictedEndTranslation: CGSize,
        style: TerminalFloatingControlPreferences.ActiveStyle,
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> EdgeHandleRelease {
        let start = edgeHandleCenter(
            for: side,
            verticalFraction: verticalFraction,
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        let current = edgeHandleDragCenter(
            for: side,
            verticalFraction: verticalFraction,
            translation: translation,
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        let predicted = edgeHandleDragCenter(
            for: side,
            verticalFraction: verticalFraction,
            translation: predictedEndTranslation,
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        let currentInwardDistance = inwardDistance(
            from: start.x,
            to: current.x,
            side: side
        )
        let predictedInwardDistance = inwardDistance(
            from: start.x,
            to: predicted.x,
            side: side
        )

        guard max(currentInwardDistance, predictedInwardDistance)
                >= edgeHandleVisualSize.width else {
            let bounds = edgeHandleBounds(
                containerSize: containerSize,
                safeAreaInsets: safeAreaInsets
            )
            let verticalFraction = bounds.height > 0
                ? Double((current.y - bounds.minY) / bounds.height)
                : TerminalFloatingControlPreferences.defaultVerticalFraction
            return .hidden(
                verticalFraction: normalizedFraction(
                    verticalFraction,
                    fallback: TerminalFloatingControlPreferences.defaultVerticalFraction
                )
            )
        }

        let releaseX = predictedInwardDistance > currentInwardDistance
            ? predicted.x
            : current.x
        let mainBounds = anchorBounds(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets,
            mainButtonSize: mainButtonSize(for: style)
        )
        let anchor = clampedCenter(
            CGPoint(x: releaseX, y: current.y),
            in: mainBounds
        )
        return .visible(normalizedPosition(for: anchor, in: mainBounds))
    }

    static func voiceStatusWidth(
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> CGFloat {
        let visibleFrame = visibleFrame(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        return min(max(visibleFrame.width - safeMargin * 2, 0), voiceStatusMaximumWidth)
    }

    static func voiceStatusCenter(
        controlFrame: CGRect,
        panelWidth: CGFloat,
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> CGPoint {
        let visibleFrame = visibleFrame(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        let horizontalBounds = axisBounds(
            minimum: visibleFrame.minX,
            maximum: visibleFrame.maxX,
            itemLength: panelWidth,
            margin: safeMargin
        )
        let verticalBounds = axisBounds(
            minimum: visibleFrame.minY,
            maximum: visibleFrame.maxY,
            itemLength: voiceStatusEstimatedHeight,
            margin: safeMargin
        )
        let above = controlFrame.minY
            - voiceStatusGap
            - voiceStatusEstimatedHeight / 2
        let below = controlFrame.maxY
            + voiceStatusGap
            + voiceStatusEstimatedHeight / 2
        let y = above >= verticalBounds.lowerBound
            ? clampedCoordinate(above, in: verticalBounds)
            : clampedCoordinate(below, in: verticalBounds)
        return CGPoint(
            x: clampedCoordinate(controlFrame.midX, in: horizontalBounds),
            y: y
        )
    }

    static func normalizedFraction(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : fallback
    }

    private static func compactSecondaryCenters(
        anchorCenter: CGPoint,
        count: Int,
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> [CGPoint] {
        guard count > 0 else { return [] }
        let bounds = secondaryActionBounds(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        let step = compactButtonSize + buttonSpacing
        let requiredDistance = CGFloat(count) * step
        let spaceBelow = bounds.maxY - anchorCenter.y
        let spaceAbove = anchorCenter.y - bounds.minY
        let direction: CGFloat
        if spaceBelow >= requiredDistance {
            direction = 1
        } else if spaceAbove >= requiredDistance {
            direction = -1
        } else {
            direction = spaceBelow >= spaceAbove ? 1 : -1
        }

        return (0 ..< count).map { index in
            CGPoint(
                x: clampedCoordinate(anchorCenter.x, in: bounds.minX ... bounds.maxX),
                y: clampedCoordinate(
                    anchorCenter.y + direction * CGFloat(index + 1) * step,
                    in: bounds.minY ... bounds.maxY
                )
            )
        }
    }

    private static func radialSecondaryCenters(
        anchorCenter: CGPoint,
        count: Int,
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> [CGPoint] {
        guard count > 0 else { return [] }
        let bounds = secondaryActionBounds(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        let region = radialRegion(anchorCenter: anchorCenter, actionBounds: bounds)
        let actionAnchor = clampedCenter(anchorCenter, in: bounds)
        let offsets = radialOffsets(count: count, region: region)
        return offsets.map { offset in
            CGPoint(
                x: clampedCoordinate(
                    actionAnchor.x + offset.x,
                    in: bounds.minX ... bounds.maxX
                ),
                y: clampedCoordinate(
                    actionAnchor.y + offset.y,
                    in: bounds.minY ... bounds.maxY
                )
            )
        }
    }

    private static func radialRegion(
        anchorCenter: CGPoint,
        actionBounds: CGRect
    ) -> RadialRegion {
        let isNearLeft = anchorCenter.x - radialOrbitRadius < actionBounds.minX
        let isNearRight = anchorCenter.x + radialOrbitRadius > actionBounds.maxX
        let isNearTop = anchorCenter.y - radialOrbitRadius < actionBounds.minY
        let isNearBottom = anchorCenter.y + radialOrbitRadius > actionBounds.maxY

        let horizontalSide: TerminalFloatingControlPreferences.HiddenSide?
        if isNearLeft && isNearRight {
            horizontalSide = anchorCenter.x <= actionBounds.midX ? .left : .right
        } else if isNearLeft {
            horizontalSide = .left
        } else if isNearRight {
            horizontalSide = .right
        } else {
            horizontalSide = nil
        }

        let verticalSide: VerticalSide?
        if isNearTop && isNearBottom {
            verticalSide = anchorCenter.y <= actionBounds.midY ? .top : .bottom
        } else if isNearTop {
            verticalSide = .top
        } else if isNearBottom {
            verticalSide = .bottom
        } else {
            verticalSide = nil
        }

        switch (horizontalSide, verticalSide) {
        case (nil, nil):
            return .center
        case (.some(let side), nil):
            return .horizontal(side)
        case (nil, .some(let side)):
            return .vertical(side)
        case (.some(let horizontal), .some(let vertical)):
            return .corner(horizontal, vertical)
        }
    }

    private static func radialOffsets(count: Int, region: RadialRegion) -> [CGPoint] {
        switch region {
        case .center:
            return (0 ..< count).map { index in
                let angle = -CGFloat.pi / 2
                    + 2 * CGFloat.pi * CGFloat(index) / CGFloat(count)
                return CGPoint(
                    x: cos(angle) * radialOrbitRadius,
                    y: sin(angle) * radialOrbitRadius
                )
            }
        case .horizontal(let side):
            let angle: CGFloat = side == .left ? 0 : .pi
            return edgeFanOffsets(count: count).map { rotate($0, by: angle) }
        case .vertical(let side):
            let angle: CGFloat = side == .top ? .pi / 2 : -.pi / 2
            return edgeFanOffsets(count: count).map { rotate($0, by: angle) }
        case .corner(let horizontal, let vertical):
            let xScale: CGFloat = horizontal == .left ? 1 : -1
            let yScale: CGFloat = vertical == .top ? 1 : -1
            return cornerFanOffsets(count: count).map { offset in
                CGPoint(x: offset.x * xScale, y: offset.y * yScale)
            }
        }
    }

    private static func edgeFanOffsets(count: Int) -> [CGPoint] {
        let candidates = [
            CGPoint(x: 0, y: -70),
            CGPoint(x: 50, y: -50),
            CGPoint(x: 112, y: -44),
            CGPoint(x: 70, y: 0),
            CGPoint(x: 112, y: 44),
            CGPoint(x: 50, y: 50),
            CGPoint(x: 0, y: 70),
        ]
        return candidateIndices(for: count).map { candidates[$0] }
    }

    private static func cornerFanOffsets(count: Int) -> [CGPoint] {
        let candidates = [
            CGPoint(x: 0, y: 126),
            CGPoint(x: 0, y: 70),
            CGPoint(x: 56, y: 104),
            CGPoint(x: 50, y: 50),
            CGPoint(x: 104, y: 56),
            CGPoint(x: 70, y: 0),
            CGPoint(x: 126, y: 0),
        ]
        return candidateIndices(for: count).map { candidates[$0] }
    }

    private static func candidateIndices(for count: Int) -> [Int] {
        switch count {
        case 1: [3]
        case 2: [1, 5]
        case 3: [1, 3, 5]
        case 4: [0, 2, 4, 6]
        case 5: [0, 1, 3, 5, 6]
        case 6: [0, 1, 2, 4, 5, 6]
        default: Array(0 ..< 7)
        }
    }

    private static func rotate(_ point: CGPoint, by angle: CGFloat) -> CGPoint {
        CGPoint(
            x: point.x * cos(angle) - point.y * sin(angle),
            y: point.x * sin(angle) + point.y * cos(angle)
        )
    }

    private static func contentFrame(
        mainCenter: CGPoint,
        mainSize: CGFloat,
        secondaryCenters: [CGPoint],
        secondarySize: CGFloat
    ) -> CGRect {
        var frame = CGRect(
            x: mainCenter.x - mainSize / 2,
            y: mainCenter.y - mainSize / 2,
            width: mainSize,
            height: mainSize
        )
        for center in secondaryCenters {
            frame = frame.union(
                CGRect(
                    x: center.x - secondarySize / 2,
                    y: center.y - secondarySize / 2,
                    width: secondarySize,
                    height: secondarySize
                )
            )
        }
        return frame
    }

    private static func secondaryActionBounds(
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> CGRect {
        centerBounds(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets,
            itemSize: CGSize(
                width: radialSecondaryButtonSize,
                height: radialSecondaryButtonSize
            ),
            margin: safeMargin
        )
    }

    private static func centerBounds(
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets,
        itemSize: CGSize,
        margin: CGFloat
    ) -> CGRect {
        let visibleFrame = visibleFrame(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        let horizontalBounds = axisBounds(
            minimum: visibleFrame.minX,
            maximum: visibleFrame.maxX,
            itemLength: itemSize.width,
            margin: margin
        )
        let verticalBounds = axisBounds(
            minimum: visibleFrame.minY,
            maximum: visibleFrame.maxY,
            itemLength: itemSize.height,
            margin: margin
        )
        return CGRect(
            x: horizontalBounds.lowerBound,
            y: verticalBounds.lowerBound,
            width: horizontalBounds.upperBound - horizontalBounds.lowerBound,
            height: verticalBounds.upperBound - verticalBounds.lowerBound
        )
    }

    private static func edgeHandleBounds(
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> CGRect {
        let visibleFrame = visibleFrame(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets
        )
        let horizontalBounds = axisBounds(
            minimum: visibleFrame.minX,
            maximum: visibleFrame.maxX,
            itemLength: edgeHandleSize.width,
            margin: 0
        )
        let verticalBounds = axisBounds(
            minimum: visibleFrame.minY,
            maximum: visibleFrame.maxY,
            itemLength: edgeHandleSize.height,
            margin: safeMargin
        )
        return CGRect(
            x: horizontalBounds.lowerBound,
            y: verticalBounds.lowerBound,
            width: horizontalBounds.upperBound - horizontalBounds.lowerBound,
            height: verticalBounds.upperBound - verticalBounds.lowerBound
        )
    }

    private static func inwardDistance(
        from startX: CGFloat,
        to endX: CGFloat,
        side: TerminalFloatingControlPreferences.HiddenSide
    ) -> CGFloat {
        switch side {
        case .left:
            max(endX - startX, 0)
        case .right:
            max(startX - endX, 0)
        }
    }

    private static func visibleFrame(
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> CGRect {
        let width = safeDimension(containerSize.width)
        let height = safeDimension(containerSize.height)
        let minimumX = min(safeDimension(safeAreaInsets.leading), width)
        let maximumX = max(
            minimumX,
            width - min(safeDimension(safeAreaInsets.trailing), width)
        )
        let minimumY = min(safeDimension(safeAreaInsets.top), height)
        let maximumY = max(
            minimumY,
            height - min(safeDimension(safeAreaInsets.bottom), height)
        )
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    private static func axisBounds(
        minimum: CGFloat,
        maximum: CGFloat,
        itemLength: CGFloat,
        margin: CGFloat
    ) -> ClosedRange<CGFloat> {
        let midpoint = minimum + (maximum - minimum) / 2
        let halfLength = safeDimension(itemLength) / 2
        let safeMargin = safeDimension(margin)
        let lowerBound = minimum + halfLength + safeMargin
        let upperBound = maximum - halfLength - safeMargin
        guard lowerBound <= upperBound else { return midpoint ... midpoint }
        return lowerBound ... upperBound
    }

    private static func clampedCoordinate(
        _ value: CGFloat,
        in range: ClosedRange<CGFloat>
    ) -> CGFloat {
        guard value.isFinite else {
            return range.lowerBound + (range.upperBound - range.lowerBound) / 2
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func clampedOffset(
        _ offset: CGFloat,
        from origin: CGFloat,
        in range: ClosedRange<CGFloat>
    ) -> CGFloat {
        guard offset.isFinite else {
            return clampedCoordinate(origin, in: range)
        }
        if offset <= range.lowerBound - origin {
            return range.lowerBound
        }
        if offset >= range.upperBound - origin {
            return range.upperBound
        }
        return origin + offset
    }

    private static func safeDimension(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), maximumLayoutDimension)
    }
}
#endif
