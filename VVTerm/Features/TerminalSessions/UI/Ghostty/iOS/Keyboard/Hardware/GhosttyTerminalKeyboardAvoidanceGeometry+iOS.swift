//
//  GhosttyTerminalKeyboardAvoidanceGeometry+iOS.swift
//  VVTerm
//
//  iOS terminal keyboard-avoidance geometry.
//

#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    func keyboardAvoidanceCursorRect() -> CGRect {
        textInputCaretRect(for: textInputModel.cursorIndex)
    }

    func keyboardAvoidanceAccessoryFrame() -> CGRect? {
        guard let keyboardToolbar,
              let accessoryWindow = keyboardToolbar.window,
              let terminalWindow = window,
              accessoryWindow.screen === terminalWindow.screen else {
            return nil
        }
        let frameInAccessoryWindow = keyboardToolbar.convert(
            keyboardToolbar.bounds,
            to: accessoryWindow
        )
        return accessoryWindow.convert(
            frameInAccessoryWindow,
            to: accessoryWindow.screen.coordinateSpace
        )
    }

    func notifyKeyboardAvoidanceAccessoryFrameChange() {
        let frame = keyboardAvoidanceAccessoryFrame()
        guard frame != lastKeyboardAvoidanceAccessoryFrame else { return }
        lastKeyboardAvoidanceAccessoryFrame = frame
        onKeyboardAvoidanceAccessoryFrameChange?()
    }

    var renderedSurfaceSize: CGSize {
        let scale = lastContentScale > 0 ? lastContentScale : contentScaleFactor
        let size = CGSize(
            width: scale > 0 ? lastPixelSize.width / scale : 0,
            height: scale > 0 ? lastPixelSize.height / scale : 0
        )
        return size.width > 0 && size.height > 0 ? size : bounds.size
    }

    func notifyKeyboardAvoidanceCursorRectIfNeeded() {
        guard let onKeyboardAvoidanceCursorRectChange else { return }
        let cursorRect = keyboardAvoidanceCursorRect()
        guard cursorRect != lastKeyboardAvoidanceCursorRect else { return }
        lastKeyboardAvoidanceCursorRect = cursorRect
        onKeyboardAvoidanceCursorRectChange(cursorRect)
    }
}

#endif
