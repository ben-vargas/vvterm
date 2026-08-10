//
//  GhosttyRuntimeCallbacks.swift
//  VVTerm
//
//  libghostty runtime callback handling.
//

import Foundation
import OSLog
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Ghostty.App {
    @MainActor
    private struct TitleDeliveryLogCache {
        static var lastUndeliveredTitleBySurface: [String: String] = [:]
    }

    // MARK: - Callbacks (macOS)

    static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let state = Ghostty.CallbackContext<Ghostty.App>.resolve(userdata) else { return }
        DispatchQueue.main.async {
            state.appTick()
        }
    }

    static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        // Get the terminal view from surface userdata if target is a surface
        var titleTargetDescription = "target \(target.tag.rawValue)"
        var activeSurfaceCount = 0
        let terminalView: GhosttyTerminalView? = {
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
            guard let surface = target.target.surface else { return nil }
            titleTargetDescription = String(describing: surface)
            if let appUserdata = ghostty_app_userdata(app) {
                let state = Ghostty.CallbackContext<Ghostty.App>.resolve(appUserdata)
                activeSurfaceCount = state?.activeSurfaceCount() ?? 0
                if let registeredView = state?.terminalView(for: surface) {
                    return registeredView
                }
            }
            guard let surfaceUserdata = ghostty_surface_userdata(surface) else { return nil }
            return Ghostty.CallbackContext<GhosttyTerminalView>.resolve(surfaceUserdata)
        }()

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            // Window/tab title change
            if let titlePtr = action.action.set_title.title {
                let title = String(cString: titlePtr)

                // Propagate to terminal view callback
                DispatchQueue.main.async {
                    guard let terminalView else {
                        if TitleDeliveryLogCache.lastUndeliveredTitleBySurface[titleTargetDescription] != title {
                            TitleDeliveryLogCache.lastUndeliveredTitleBySurface[titleTargetDescription] = title
                            Ghostty.logger.warning(
                                "Ghostty title received without terminal view: \(title, privacy: .public), target: \(titleTargetDescription, privacy: .public), active surfaces: \(activeSurfaceCount)"
                            )
                        }
                        return
                    }

                    guard terminalView.onTitleChange != nil else {
                        if TitleDeliveryLogCache.lastUndeliveredTitleBySurface[titleTargetDescription] != title {
                            TitleDeliveryLogCache.lastUndeliveredTitleBySurface[titleTargetDescription] = title
                            Ghostty.logger.warning(
                                "Ghostty title received before title callback was installed: \(title, privacy: .public), target: \(titleTargetDescription, privacy: .public)"
                            )
                        }
                        return
                    }

                    terminalView.onTitleChange?(title)
                }
            }
            return true

        case GHOSTTY_ACTION_PWD:
            // Working directory change
            if let pwdPtr = action.action.pwd.pwd {
                let pwd = String(cString: pwdPtr)
                Ghostty.logger.info("PWD changed: \(pwd)")
                DispatchQueue.main.async {
                    terminalView?.onPwdChange?(pwd)
                }
            }
            return true

        case GHOSTTY_ACTION_PROMPT_TITLE:
            // Prompt title update (for shell integration)
            Ghostty.logger.debug("Prompt title action received")
            return true

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let report = action.action.progress_report
            let state = GhosttyProgressState(cState: report.state)
            let value = report.progress >= 0 ? Int(report.progress) : nil
            DispatchQueue.main.async {
                terminalView?.onProgressReport?(state, value)
            }
            return true

        case GHOSTTY_ACTION_START_SEARCH:
            #if os(iOS)
            let needle = action.action.start_search.needle.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                terminalView?.handleGhosttySearchStarted(needle: needle)
            }
            return true
            #else
            return false
            #endif

        case GHOSTTY_ACTION_END_SEARCH:
            #if os(iOS)
            DispatchQueue.main.async {
                terminalView?.handleGhosttySearchEnded()
            }
            return true
            #else
            return false
            #endif

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            #if os(iOS)
            let total = action.action.search_total.total >= 0 ? Int(action.action.search_total.total) : nil
            DispatchQueue.main.async {
                terminalView?.handleGhosttySearchTotalChange(total)
            }
            return true
            #else
            return false
            #endif

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            #if os(iOS)
            let selected = action.action.search_selected.selected >= 0 ? Int(action.action.search_selected.selected) : nil
            DispatchQueue.main.async {
                terminalView?.handleGhosttySearchSelectedChange(selected)
            }
            return true
            #else
            return false
            #endif

        case GHOSTTY_ACTION_CELL_SIZE:
            // Cell size update - used for row-to-pixel conversion in scrollbar
            #if os(macOS)
            let cellSize = action.action.cell_size
            let backingSize = NSSize(width: Double(cellSize.width), height: Double(cellSize.height))
            DispatchQueue.main.async {
                guard let terminalView = terminalView else { return }
                // Convert from backing (pixel) coordinates to points
                terminalView.cellSize = terminalView.convertFromBacking(backingSize)
            }
            #else
            let cellSize = action.action.cell_size
            DispatchQueue.main.async {
                guard let terminalView = terminalView else { return }
                // Convert from backing (pixel) coordinates to points
                let scale = terminalView.window?.screen.scale ?? max(terminalView.traitCollection.displayScale, 1)
                terminalView.cellSize = CGSize(
                    width: Double(cellSize.width) / scale,
                    height: Double(cellSize.height) / scale
                )
            }
            #endif
            return true

        case GHOSTTY_ACTION_SCROLLBAR:
            // Scrollbar state update - post notification for scroll view
            let scrollbar = Ghostty.Action.Scrollbar(c: action.action.scrollbar)
            NotificationCenter.default.post(
                name: .ghosttyDidUpdateScrollbar,
                object: terminalView,
                userInfo: [Notification.Name.ScrollbarKey: scrollbar]
            )
            return true

        case GHOSTTY_ACTION_READONLY:
            let isReadonly = action.action.readonly == GHOSTTY_READONLY_ON
            DispatchQueue.main.async {
                terminalView?.updateReadonlyState(isReadonly)
            }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE,
             GHOSTTY_ACTION_MOUSE_VISIBILITY,
             GHOSTTY_ACTION_MOUSE_OVER_LINK:
            #if os(iOS)
            return true
            #else
            Ghostty.logger.debug("Action received: \(action.tag.rawValue) on target: \(target.tag.rawValue)")
            return false
            #endif

        default:
            // Log unhandled actions
            Ghostty.logger.debug("Action received: \(action.tag.rawValue) on target: \(target.tag.rawValue)")
            return false
        }
    }

    static func readClipboard(_ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) {
        guard let terminalView = Ghostty.CallbackContext<GhosttyTerminalView>.resolve(userdata) else { return }
        guard let surface = terminalView.surface?.unsafeCValue else { return }

        // Read from macOS clipboard
        let clipboardString = Clipboard.readString() ?? ""

        // Complete the clipboard request by providing data to Ghostty
        clipboardString.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
        }

        Ghostty.logger.debug("Read clipboard [bytes: \(clipboardString.utf8.count)]")
    }

    static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let terminalView = Ghostty.CallbackContext<GhosttyTerminalView>.resolve(userdata),
              let string,
              let state else { return }
        let clipboardString = String(cString: string)
        terminalView.handleClipboardConfirmation(
            clipboardString,
            state: state,
            kind: clipboardConfirmationKind(request: request)
        )
        Ghostty.logger.debug("Queued clipboard confirmation request: \(request.rawValue)")
    }

    nonisolated static func clipboardConfirmationKind(
        request: ghostty_clipboard_request_e
    ) -> TerminalClipboardConfirmationKind {
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
            return .unsafePaste
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
            return .remoteRead
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
            return .remoteWrite
        default:
            return .remoteRead
        }
    }

    static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int,
        confirm: Bool
    ) {
        guard let contents = contents, count > 0 else { return }
        guard let terminalView = Ghostty.CallbackContext<GhosttyTerminalView>.resolve(userdata) else { return }
        #if os(iOS)
        guard location != GHOSTTY_CLIPBOARD_SELECTION else { return }
        #endif

        // The runtime passes an array of clipboard entries; prefer the first
        // textual entry. The API does not supply a byte length, so we treat
        // the data as a null-terminated UTF-8 C string.
        for idx in 0..<count {
            let entry = contents.advanced(by: idx).pointee
            guard let dataPtr = entry.data else { continue }

            var string = String(cString: dataPtr)
            if !string.isEmpty {
                // Apply copy transformations from settings
                string = TerminalTextCleaner.cleanText(string, settings: .current())

                let action = TerminalClipboardWritePolicy.action(
                    requiresConfirmation: confirm
                )
                DispatchQueue.main.async {
                    terminalView.handleClipboardWrite(string, action: action)
                }
                Ghostty.logger.debug(
                    "Handled clipboard write [bytes: \(string.utf8.count)] [confirmation: \(confirm)]"
                )
                return
            }
        }
    }

    static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let terminalView = Ghostty.CallbackContext<GhosttyTerminalView>.resolve(userdata) else { return }

        Ghostty.logger.info("Close surface: processAlive=\(processAlive)")

        // Trigger process exit callback on main thread
        DispatchQueue.main.async {
            terminalView.onProcessExit?()
        }
    }
}
