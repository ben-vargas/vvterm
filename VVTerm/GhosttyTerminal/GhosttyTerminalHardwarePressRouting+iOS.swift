//
//  GhosttyTerminalHardwarePressRouting+iOS.swift
//  VVTerm
//
//  iOS hardware press routing into terminal and system text input.
//

#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    private func shouldRedirectNativeSelectionPressesToTerminalInput(_ presses: Set<UIPress>) -> Bool {
        guard isNativeSelectionTextInputContext else { return false }
        return presses.contains { press in
            guard let key = press.key else { return false }
            return !key.modifierFlags.contains(.command)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if shouldRedirectNativeSelectionPressesToTerminalInput(presses) {
            guard exitNativeSelectionTextInputContextForTerminalInput() else {
                super.pressesBegan(presses, with: event)
                return
            }
            imeProxyTextView.pressesBegan(presses, with: event)
            return
        }

        let pendingCount = pendingSystemTextInputHardwareKeys.count
        let result = processHardwarePressesBegan(presses, event: event)
        if !result.forwardedToSystem.isEmpty {
            super.pressesBegan(result.forwardedToSystem, with: event)
            removeUnconsumedPendingSystemTextInputHardwareKeys(after: pendingCount)
        }

        if result.didHandleGhosttyInput {
            requestRender()
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let result = processHardwarePressesEnded(presses, event: event)
        if !result.forwardedToSystem.isEmpty {
            super.pressesEnded(result.forwardedToSystem, with: event)
        }

        if result.didHandleGhosttyInput {
            requestRender()
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(presses, with: event)
        processHardwarePressesCancelled(presses)
    }
}

#endif
