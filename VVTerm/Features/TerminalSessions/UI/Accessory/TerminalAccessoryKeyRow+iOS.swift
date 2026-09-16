#if os(iOS)
import UIKit

/// Shared capsule row. Each input mode owns its actions and modifier state.
class TerminalAccessoryKeyRow: UIView, UIScrollViewDelegate {
    let stack = UIStackView()
    let scroll = UIScrollView()
    private let leftBlur = AccessoryEdgeBlur(isLeft: true)
    private let rightBlur = AccessoryEdgeBlur(isLeft: false)
    private let edgeMask = CAGradientLayer()

    init(contentInset: CGFloat = 24) {
        super.init(frame: .zero)
        edgeMask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        edgeMask.startPoint = CGPoint(x: 0, y: 0.5)
        edgeMask.endPoint = CGPoint(x: 1, y: 0.5)
        scroll.contentInset = UIEdgeInsets(top: 0, left: contentInset, bottom: 0, right: contentInset)
        scroll.contentOffset.x = -contentInset
        layer.mask = edgeMask
        scroll.delegate = self
        // Keep glass shadows outside the row height; the mask clips only its horizontal ends.
        scroll.clipsToBounds = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        stack.axis = .horizontal
        stack.spacing = 0
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 0),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: 0),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        for (edge, isLeft) in [(leftBlur, true), (rightBlur, false)] {
            edge.translatesAutoresizingMaskIntoConstraints = false
            addSubview(edge)
            NSLayoutConstraint.activate([
                edge.topAnchor.constraint(equalTo: topAnchor),
                edge.bottomAnchor.constraint(equalTo: bottomAnchor),
                edge.widthAnchor.constraint(equalToConstant: 44),
                isLeft ? edge.leftAnchor.constraint(equalTo: leftAnchor)
                    : edge.rightAnchor.constraint(equalTo: rightAnchor)
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.layoutIfNeeded()
        updateEdgeFades()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateEdgeFades() }

    private func updateEdgeFades() {
        let showsLeft = scroll.contentOffset.x > -scroll.adjustedContentInset.left + 0.5
        let showsRight = scroll.contentOffset.x + scroll.bounds.width < scroll.contentSize.width + scroll.adjustedContentInset.right - 0.5
        leftBlur.isHidden = !showsLeft
        rightBlur.isHidden = !showsRight
        let fraction = min(0.5, 44 / max(bounds.width, 1))
        let steps = (0...8).map { CGFloat($0) / 8 }
        let leadingColors = steps.map { UIColor.black.withAlphaComponent(showsLeft ? $0 * $0 * (3 - 2 * $0) : 1).cgColor }
        let trailingColors = steps.map { UIColor.black.withAlphaComponent(showsRight ? 1 - $0 * $0 * (3 - 2 * $0) : 1).cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeMask.frame = bounds.insetBy(dx: 0, dy: -16)
        edgeMask.colors = leadingColors + trailingColors
        edgeMask.locations = steps.map { NSNumber(value: Double($0 * fraction)) }
            + steps.map { NSNumber(value: Double(1 - fraction + $0 * fraction)) }
        CATransaction.commit()
    }
}

/// The row's outer mask fades this blur too, so no material strip remains at the edge.
private final class AccessoryEdgeBlur: UIVisualEffectView {
    private let fade = CAGradientLayer()
    private let verticalFade = CAGradientLayer()

    init(isLeft: Bool) {
        super.init(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        fade.colors = [UIColor.black.withAlphaComponent(0.7).cgColor,
                       UIColor.black.withAlphaComponent(0.25).cgColor, UIColor.clear.cgColor]
        fade.locations = [0, 0.5, 1]
        fade.startPoint = CGPoint(x: isLeft ? 0 : 1, y: 0.5)
        fade.endPoint = CGPoint(x: isLeft ? 1 : 0, y: 0.5)
        verticalFade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        verticalFade.locations = [0, 0.3, 0.7, 1]
        fade.mask = verticalFade
        layer.mask = fade
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        verticalFade.frame = fade.bounds
        CATransaction.commit()
    }
}
#endif
