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

private nonisolated enum GhosttyRuntimeAction: Sendable {
    case title(String)
    case workingDirectory(String)
    case promptTitle
    case progress(stateRawValue: UInt32, value: Int?)
    #if os(iOS)
    case startSearch(String)
    case endSearch
    case searchTotal(Int?)
    case searchSelected(Int?)
    #endif
    case cellSize(width: UInt32, height: UInt32)
    case scrollbar(Ghostty.Action.Scrollbar)
    case readonly(Bool)
}
private nonisolated enum GhosttyRuntimeActionDisposition: Sendable {
    case deliver(GhosttyRuntimeAction)
    case handled
    case unhandled
}

private nonisolated struct GhosttyRuntimeActionTarget: Sendable {
    let app: GhosttyRuntime?
    let surfaceAddress: UInt?
    let fallbackTerminalView: GhosttyTerminalView?
    let description: String
    let tagRawValue: UInt32
}

extension GhosttyRuntime {
    @MainActor
    private struct TitleDeliveryLogCache {
        static var lastUndeliveredTitleBySurface: [String: String] = [:]
    }

    /// Builds C callbacks outside the app's Main Actor isolation. libghostty may
    /// invoke every callback from its renderer thread.
    nonisolated static func makeRuntimeConfiguration(
        userdata: UnsafeMutableRawPointer?,
        supportsSelectionClipboard: Bool
    ) -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: userdata,
            supports_selection_clipboard: supportsSelectionClipboard,
            wakeup_cb: { userdata in GhosttyRuntime.wakeup(userdata) },
            action_cb: { app, target, action in
                guard let app else { return false }
                return GhosttyRuntime.runtimeAction(app, target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state, mimes, mimesLength, list in
                GhosttyRuntime.readClipboard(
                    userdata,
                    location: location,
                    state: state,
                    mimes: mimes,
                    mimesLength: mimesLength,
                    list: list
                )
            },
            confirm_read_clipboard_cb: { userdata, confirmation, state, request in
                GhosttyRuntime.confirmReadClipboard(
                    userdata,
                    confirmation: confirmation,
                    state: state,
                    request: request
                )
            },
            write_clipboard_cb: { userdata, location, contents, count, confirm in
                GhosttyRuntime.writeClipboard(
                    userdata,
                    location: location,
                    contents: contents,
                    count: count,
                    confirm: confirm
                )
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyRuntime.closeSurface(userdata, processAlive: processAlive)
            }
        )
    }

    // MARK: - Native callback boundary

    nonisolated private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let app = Ghostty.CallbackContext<GhosttyRuntime>.resolve(userdata) else { return }
        DispatchQueue.main.async {
            app.appTick()
        }
    }

    nonisolated private static func runtimeAction(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        let actionTarget = makeActionTarget(app: app, target: target)
        switch decode(action) {
        case .deliver(let runtimeAction):
            DispatchQueue.main.async {
                deliver(runtimeAction, to: actionTarget)
            }
            return true

        case .handled:
            return true

        case .unhandled:
            DispatchQueue.main.async {
                Ghostty.logger.debug(
                    "Action received: \(action.tag.rawValue) on target: \(actionTarget.tagRawValue)"
                )
            }
            return false
        }
    }

    nonisolated private static func makeActionTarget(
        app: ghostty_app_t,
        target: ghostty_target_s
    ) -> GhosttyRuntimeActionTarget {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface else {
            return GhosttyRuntimeActionTarget(
                app: nil,
                surfaceAddress: nil,
                fallbackTerminalView: nil,
                description: "target \(target.tag.rawValue)",
                tagRawValue: target.tag.rawValue
            )
        }

        let appOwner = ghostty_app_userdata(app).flatMap {
            Ghostty.CallbackContext<GhosttyRuntime>.resolve($0)
        }
        let fallbackTerminalView = ghostty_surface_userdata(surface).flatMap {
            Ghostty.CallbackContext<GhosttyTerminalView>.resolve($0)
        }
        return GhosttyRuntimeActionTarget(
            app: appOwner,
            surfaceAddress: UInt(bitPattern: surface),
            fallbackTerminalView: fallbackTerminalView,
            description: String(describing: surface),
            tagRawValue: target.tag.rawValue
        )
    }

    nonisolated private static func decode(
        _ action: ghostty_action_s
    ) -> GhosttyRuntimeActionDisposition {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let title = action.action.set_title.title else { return .handled }
            return .deliver(.title(String(cString: title)))

        case GHOSTTY_ACTION_PWD:
            guard let pwd = action.action.pwd.pwd else { return .handled }
            return .deliver(.workingDirectory(String(cString: pwd)))

        case GHOSTTY_ACTION_PROMPT_TITLE:
            return .deliver(.promptTitle)

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let report = action.action.progress_report
            return .deliver(.progress(
                stateRawValue: report.state.rawValue,
                value: report.progress >= 0 ? Int(report.progress) : nil
            ))

        case GHOSTTY_ACTION_START_SEARCH:
            #if os(iOS)
            let needle = action.action.start_search.needle.map { String(cString: $0) } ?? ""
            return .deliver(.startSearch(needle))
            #else
            return .unhandled
            #endif

        case GHOSTTY_ACTION_END_SEARCH:
            #if os(iOS)
            return .deliver(.endSearch)
            #else
            return .unhandled
            #endif

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            #if os(iOS)
            let total = action.action.search_total.total
            return .deliver(.searchTotal(total >= 0 ? Int(total) : nil))
            #else
            return .unhandled
            #endif

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            #if os(iOS)
            let selected = action.action.search_selected.selected
            return .deliver(.searchSelected(selected >= 0 ? Int(selected) : nil))
            #else
            return .unhandled
            #endif

        case GHOSTTY_ACTION_CELL_SIZE:
            let cellSize = action.action.cell_size
            return .deliver(.cellSize(width: cellSize.width, height: cellSize.height))

        case GHOSTTY_ACTION_SCROLLBAR:
            return .deliver(.scrollbar(Ghostty.Action.Scrollbar(c: action.action.scrollbar)))

        case GHOSTTY_ACTION_READONLY:
            return .deliver(.readonly(action.action.readonly == GHOSTTY_READONLY_ON))

        case GHOSTTY_ACTION_MOUSE_SHAPE,
             GHOSTTY_ACTION_MOUSE_VISIBILITY,
             GHOSTTY_ACTION_MOUSE_OVER_LINK:
            #if os(iOS)
            return .handled
            #else
            return .unhandled
            #endif

        default:
            return .unhandled
        }
    }

    nonisolated private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLength: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard location != GHOSTTY_CLIPBOARD_PRIMARY,
              let terminalView = Ghostty.CallbackContext<GhosttyTerminalView>.resolve(userdata),
              let state else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }
        guard list || requestsPlainText(mimes: mimes, count: mimesLength) else {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }
        let stateAddress = UInt(bitPattern: state)

        DispatchQueue.main.async {
            guard let surface = terminalView.surface?.unsafeCValue else { return }
            let clipboardString = Clipboard.readString()
            let callbackState = UnsafeMutableRawPointer(bitPattern: stateAddress)
            completeClipboardRequest(
                surface: surface,
                text: clipboardString,
                availableMIMETypes: list && clipboardString != nil ? ["text/plain"] : [],
                state: callbackState,
                confirmed: false
            )
            Ghostty.logger.debug("Read clipboard [bytes: \(clipboardString?.utf8.count ?? 0)]")
        }
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    nonisolated private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        confirmation: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let terminalView = Ghostty.CallbackContext<GhosttyTerminalView>.resolve(userdata),
              let state else { return }
        let stateAddress = UInt(bitPattern: state)

        guard let confirmation else {
            DispatchQueue.main.async {
                guard let surface = terminalView.surface?.unsafeCValue,
                      let callbackState = UnsafeMutableRawPointer(bitPattern: stateAddress) else {
                    return
                }
                ghostty_surface_deny_clipboard_request(surface, callbackState)
            }
            return
        }

        let value = confirmation.pointee
        let clipboardString = plainText(contents: value.contents, count: value.contents_len)
        let availableMIMETypes = copiedStrings(value.available, count: value.available_len)
        let kind = clipboardConfirmationKind(request: request)

        DispatchQueue.main.async {
            guard let callbackState = UnsafeMutableRawPointer(bitPattern: stateAddress) else { return }
            terminalView.handleClipboardConfirmation(
                clipboardString,
                availableMIMETypes: availableMIMETypes,
                state: callbackState,
                kind: kind
            )
            Ghostty.logger.debug("Queued clipboard confirmation request: \(request.rawValue)")
        }
    }

    nonisolated static func clipboardConfirmationKind(
        request: ghostty_clipboard_request_e
    ) -> TerminalClipboardConfirmationKind {
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
            return .unsafePaste
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
             GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ,
             GHOSTTY_CLIPBOARD_REQUEST_LIST:
            return .remoteRead
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
             GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE:
            return .remoteWrite
        default:
            return .remoteRead
        }
    }

    nonisolated private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int,
        confirm: Bool
    ) {
        guard let contents, count > 0 else { return }
        guard let terminalView = Ghostty.CallbackContext<GhosttyTerminalView>.resolve(userdata) else { return }
        #if os(iOS)
        guard location != GHOSTTY_CLIPBOARD_SELECTION else { return }
        #endif

        for index in 0..<count {
            let entry = contents.advanced(by: index).pointee
            guard let mime = entry.mime,
                  String(cString: mime) == "text/plain",
                  let data = entry.data else { continue }
            let bytes = UnsafeRawBufferPointer(start: data, count: entry.len)
            let string = String(decoding: bytes, as: UTF8.self)
            guard !string.isEmpty else { continue }

            DispatchQueue.main.async {
                let cleanedString = TerminalTextCleaner.cleanText(
                    string,
                    settings: .current()
                )
                let action = TerminalClipboardWritePolicy.action(
                    requiresConfirmation: confirm
                )
                terminalView.handleClipboardWrite(cleanedString, action: action)
                Ghostty.logger.debug(
                    "Handled clipboard write [bytes: \(cleanedString.utf8.count)] [confirmation: \(confirm)]"
                )
            }
            return
        }
    }

    nonisolated static func completeClipboardRequest(
        surface: ghostty_surface_t,
        text: String?,
        availableMIMETypes: [String],
        state: UnsafeMutableRawPointer?,
        confirmed: Bool
    ) {
        let contents: [(mime: String, data: Data)]
        if let text {
            contents = [(mime: "text/plain", data: Data(text.utf8))]
        } else {
            contents = []
        }

        var allocatedStrings: [UnsafeMutablePointer<CChar>] = []
        var allocatedData: [UnsafeMutableRawPointer] = []
        defer {
            allocatedStrings.forEach { free($0) }
            allocatedData.forEach { $0.deallocate() }
        }

        var cContents: [ghostty_clipboard_content_s] = []
        for entry in contents {
            guard let mime = strdup(entry.mime) else { continue }
            allocatedStrings.append(mime)

            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: max(entry.data.count, 1),
                alignment: 1
            )
            allocatedData.append(buffer)
            entry.data.withUnsafeBytes { source in
                guard let sourceAddress = source.baseAddress else { return }
                buffer.copyMemory(from: sourceAddress, byteCount: source.count)
            }
            cContents.append(ghostty_clipboard_content_s(
                mime: mime,
                data: buffer.assumingMemoryBound(to: CChar.self),
                len: entry.data.count
            ))
        }

        var cAvailableMIMETypes: [UnsafePointer<CChar>?] = []
        for availableMIMEType in availableMIMETypes {
            guard let mime = strdup(availableMIMEType) else { continue }
            allocatedStrings.append(mime)
            cAvailableMIMETypes.append(UnsafePointer(mime))
        }

        cContents.withUnsafeBufferPointer { contentBuffer in
            cAvailableMIMETypes.withUnsafeBufferPointer { availableBuffer in
                var completion = ghostty_clipboard_complete_s(
                    contents: contentBuffer.baseAddress,
                    contents_len: contentBuffer.count,
                    available: availableBuffer.baseAddress,
                    available_len: availableBuffer.count,
                    confirmed: confirmed,
                    remember: false
                )
                ghostty_surface_complete_clipboard_request(
                    surface,
                    &completion,
                    state
                )
            }
        }
    }

    nonisolated private static func requestsPlainText(
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        count: Int
    ) -> Bool {
        guard let mimes, count > 0 else { return false }
        for index in 0..<count {
            guard let mime = mimes[index] else { continue }
            if String(cString: mime) == "text/plain" {
                return true
            }
        }
        return false
    }

    nonisolated private static func plainText(
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int
    ) -> String? {
        guard let contents, count > 0 else { return nil }
        for index in 0..<count {
            let content = contents[index]
            guard let mime = content.mime,
                  String(cString: mime) == "text/plain",
                  let data = content.data else { continue }
            return String(
                decoding: UnsafeRawBufferPointer(start: data, count: content.len),
                as: UTF8.self
            )
        }
        return nil
    }

    nonisolated private static func copiedStrings(
        _ strings: UnsafePointer<UnsafePointer<CChar>?>?,
        count: Int
    ) -> [String] {
        guard let strings, count > 0 else { return [] }
        var result: [String] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard let string = strings[index] else { continue }
            result.append(String(cString: string))
        }
        return result
    }

    nonisolated private static func closeSurface(
        _ userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let terminalView = Ghostty.CallbackContext<GhosttyTerminalView>.resolve(userdata) else { return }
        DispatchQueue.main.async {
            Ghostty.logger.info("Close surface: processAlive=\(processAlive)")
            terminalView.onProcessExit?()
        }
    }

    // MARK: - Main Actor delivery

    private static func deliver(
        _ action: GhosttyRuntimeAction,
        to target: GhosttyRuntimeActionTarget
    ) {
        let registeredTerminalView: GhosttyTerminalView?
        if let surfaceAddress = target.surfaceAddress,
           let surface = UnsafeMutableRawPointer(bitPattern: surfaceAddress),
           let app = target.app {
            registeredTerminalView = app.terminalView(for: surface)
        } else {
            registeredTerminalView = nil
        }
        let terminalView = registeredTerminalView ?? target.fallbackTerminalView

        switch action {
        case .title(let title):
            guard let terminalView else {
                if TitleDeliveryLogCache.lastUndeliveredTitleBySurface[target.description] != title {
                    TitleDeliveryLogCache.lastUndeliveredTitleBySurface[target.description] = title
                    Ghostty.logger.warning(
                        "Ghostty title received without terminal view: \(title, privacy: .public), target: \(target.description, privacy: .public), active surfaces: \(target.app?.activeSurfaceCount() ?? 0)"
                    )
                }
                return
            }
            guard terminalView.onTitleChange != nil else {
                if TitleDeliveryLogCache.lastUndeliveredTitleBySurface[target.description] != title {
                    TitleDeliveryLogCache.lastUndeliveredTitleBySurface[target.description] = title
                    Ghostty.logger.warning(
                        "Ghostty title received before title callback was installed: \(title, privacy: .public), target: \(target.description, privacy: .public)"
                    )
                }
                return
            }
            terminalView.onTitleChange?(title)

        case .workingDirectory(let path):
            Ghostty.logger.info("PWD changed: \(path)")
            terminalView?.onPwdChange?(path)

        case .promptTitle:
            Ghostty.logger.debug("Prompt title action received")

        case .progress(let stateRawValue, let value):
            let cState = ghostty_action_progress_report_state_e(rawValue: stateRawValue)
            terminalView?.onProgressReport?(GhosttyProgressState(cState: cState), value)

        #if os(iOS)
        case .startSearch(let needle):
            terminalView?.handleGhosttySearchStarted(needle: needle)

        case .endSearch:
            terminalView?.handleGhosttySearchEnded()

        case .searchTotal(let total):
            terminalView?.handleGhosttySearchTotalChange(total)

        case .searchSelected(let selected):
            terminalView?.handleGhosttySearchSelectedChange(selected)
        #endif

        case .cellSize(let width, let height):
            guard let terminalView else { return }
            #if os(macOS)
            let backingSize = NSSize(width: Double(width), height: Double(height))
            terminalView.cellSize = terminalView.convertFromBacking(backingSize)
            #else
            let scale = terminalView.window?.screen.scale
                ?? max(terminalView.traitCollection.displayScale, 1)
            terminalView.cellSize = CGSize(
                width: Double(width) / scale,
                height: Double(height) / scale
            )
            #endif

        case .scrollbar(let scrollbar):
            NotificationCenter.default.post(
                name: .ghosttyDidUpdateScrollbar,
                object: terminalView,
                userInfo: [Notification.Name.ScrollbarKey: scrollbar]
            )

        case .readonly(let isReadonly):
            terminalView?.updateReadonlyState(isReadonly)
        }
    }
}
