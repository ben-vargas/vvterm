//
//  GhosttyTerminalPointerMenuPresentation+iOS.swift
//  VVTerm
//
//  iOS pointer context-menu presentation.
//

#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    func showPointerContextMenu(at location: CGPoint) {
        dismissEditMenuIfNeeded()
        editMenuPresentation = .pointerContext
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: location)
        editMenuInteraction?.presentEditMenu(with: config)
    }

    private func focusPointerContextTarget() {
        focusForHardwareKeyboardIfNeeded()
        terminalContextMenuActions?.focus()
    }

    func pointerContextMenuElements() -> [UIMenuElement] {
        var actions: [UIMenuElement] = []

        if let selectionText = currentSelectionText(), !selectionText.isEmpty {
            actions.append(UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.focusPointerContextTarget()
                self?.copy(nil)
            })
        }

        actions.append(UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            self?.focusPointerContextTarget()
            self?.paste(nil)
        })

        if let terminalContextMenuActions {
            actions.append(UIMenu(options: .displayInline, children: [
                UIAction(title: String(localized: "Split Right"), image: UIImage(systemName: "rectangle.righthalf.inset.filled")) { [weak self] _ in
                    self?.focusPointerContextTarget()
                    terminalContextMenuActions.splitRight()
                },
                UIAction(title: String(localized: "Split Left"), image: UIImage(systemName: "rectangle.leadinghalf.inset.filled")) { [weak self] _ in
                    self?.focusPointerContextTarget()
                    terminalContextMenuActions.splitLeft()
                },
                UIAction(title: String(localized: "Split Down"), image: UIImage(systemName: "rectangle.bottomhalf.inset.filled")) { [weak self] _ in
                    self?.focusPointerContextTarget()
                    terminalContextMenuActions.splitDown()
                },
                UIAction(title: String(localized: "Split Up"), image: UIImage(systemName: "rectangle.tophalf.inset.filled")) { [weak self] _ in
                    self?.focusPointerContextTarget()
                    terminalContextMenuActions.splitUp()
                }
            ]))
        }

        actions.append(UIMenu(options: .displayInline, children: [
            UIAction(title: String(localized: "Reset Terminal"), image: UIImage(systemName: "arrow.trianglehead.2.clockwise")) { [weak self] _ in
                self?.focusPointerContextTarget()
                self?.resetTerminalForReconnect()
            },
            UIAction(
                title: String(localized: "Terminal Read-only"),
                image: UIImage(systemName: "eye.fill"),
                state: readonly ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                self.focusPointerContextTarget()
                if self.surface?.perform(action: "toggle_readonly") == true {
                    self.readonly.toggle()
                }
            }
        ]))

        if terminalContextMenuActions != nil {
            actions.append(UIMenu(options: .displayInline, children: [
                UIAction(title: String(localized: "Change Terminal Title..."), image: UIImage(systemName: "pencil")) { [weak self] _ in
                    self?.presentTerminalTitleEditor()
                }
            ]))
        }

        return actions
    }

    private func presentTerminalTitleEditor() {
        guard let terminalContextMenuActions else { return }
        focusPointerContextTarget()

        let alert = UIAlertController(
            title: String(localized: "Change Terminal Title"),
            message: String(localized: "Leave blank to restore the default."),
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = terminalContextMenuActions.currentTitle()
            textField.clearButtonMode = .whileEditing
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in
            let title = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            terminalContextMenuActions.setTitle(title.isEmpty ? nil : title)
        })

        nearestPresentingViewController()?.present(alert, animated: true)
    }
}

#endif
