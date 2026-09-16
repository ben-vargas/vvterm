#if os(iOS)
import UIKit

enum TerminalAccessoryButtonStyle {
    static func configuration(title: String = "", icon: String? = nil) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration.background.backgroundColor = .tertiarySystemFill
        }
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .init(top: 6, leading: 12, bottom: 6, trailing: 12)
        configuration.baseForegroundColor = .label
        if let icon {
            configuration.image = UIImage(systemName: icon)
            configuration.preferredSymbolConfigurationForImage = .init(pointSize: 13, weight: .medium)
        } else {
            configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 13, weight: .medium)
            ]))
        }
        // The visible capsule is smaller than the button's touch area.
        configuration.background.backgroundInsets = .init(top: 6, leading: 4, bottom: 6, trailing: 4)
        return configuration
    }

    static func apply(to button: UIButton, title: String = "", icon: String? = nil) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.configuration = configuration(title: title, icon: icon)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            button.heightAnchor.constraint(equalToConstant: 40)
        ])
    }
}
#endif
