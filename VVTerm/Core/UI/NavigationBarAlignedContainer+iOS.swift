#if os(iOS)
import SwiftUI
import UIKit

/// Aligns content with the outer edges of the native navigation bar controls.
struct NavigationBarAlignedContainer<Content: View>: UIViewControllerRepresentable {
    @ViewBuilder let content: Content

    func makeUIViewController(context: Context) -> Controller {
        Controller(content: AnyView(content.environment(\.self, context.environment)))
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.host.rootView = AnyView(content.environment(\.self, context.environment))
    }

    final class Controller: UIViewController {
        let host: UIHostingController<AnyView>

        init(content: AnyView) {
            host = UIHostingController(rootView: content)
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            if #available(iOS 26, *), traitCollection.userInterfaceIdiom == .pad {
                // iPad's toolbar glass uses a 10-point edge inset. iPhone uses
                // the system margins, which vary with the device and window.
                viewRespectsSystemMinimumLayoutMargins = false
                view.directionalLayoutMargins = NSDirectionalEdgeInsets(
                    top: 0, leading: 10, bottom: 0, trailing: 10
                )
            } else {
                view.directionalLayoutMargins = .zero
            }
            addChild(host)
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            host.didMove(toParent: self)
        }
    }
}
#endif
