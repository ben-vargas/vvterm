import SwiftUI

/// Matches Ghostty's two-point surface bar without changing terminal geometry.
struct TerminalProgressBar: View {
    let progress: TerminalProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: CGFloat = 0

    private var color: Color {
        switch progress {
        case .error: .red
        case .paused: .orange
        default: .accentColor
        }
    }

    private var label: String {
        switch progress {
        case .error: String(localized: "Terminal progress - Error")
        case .paused: String(localized: "Terminal progress - Paused")
        case .indeterminate: String(localized: "Operation in progress")
        default: String(localized: "Terminal progress")
        }
    }

    private var value: String {
        if let percent = progress.percent {
            return String(localized: "\(percent) percent complete")
        }
        switch progress {
        case .error: return String(localized: "Operation failed")
        case .paused: return String(localized: "Operation paused")
        default: return String(localized: "Operation in progress")
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if let percent = progress.barPercent {
                    Rectangle()
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(percent) / 100)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: percent)
                } else {
                    Rectangle().fill(color.opacity(0.3))
                    Rectangle()
                        .fill(color)
                        .frame(width: geometry.size.width * 0.25)
                        .offset(x: position * geometry.size.width * 0.75)
                        // The iOS terminal container clears inherited animations.
                        // Keep motion local to this segment, away from Metal views.
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                            value: position
                        )
                }
            }
        }
        .frame(height: 2)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityRepresentation {
            Group {
                if let percent = progress.percent {
                    ProgressView(value: Double(percent), total: 100)
                } else {
                    ProgressView()
                }
            }
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityAddTraits(.updatesFrequently)
        }
        .task(id: progress.barPercent == nil && !reduceMotion) {
            position = 0
            if progress.barPercent == nil && !reduceMotion {
                position = 1
            }
        }
    }
}
