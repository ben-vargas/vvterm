import SwiftUI

struct ServerWakeNoticeHost<Content: View>: View {
    @ObservedObject private var coordinator: ServerWakeCoordinator
    @StateObject private var noticeHost = NoticeHostModel()
    private let content: Content

    init(
        coordinator: ServerWakeCoordinator,
        @ViewBuilder content: () -> Content
    ) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        self.content = content()
    }

    var body: some View {
        NoticeHost(bottomOperations: noticeHost.bottomOperations) {
            content
        }
        .onReceive(coordinator.$phase) { phase in
            present(phase)
        }
    }

    private func present(_ phase: ServerWakePhase) {
        switch phase {
        case .idle:
            noticeHost.set(nil, for: .bottomOperation)

        case .sending(let operationID):
            noticeHost.set(nil, for: .bottomOperation)
            noticeHost.show(
                operationNotice(
                    operationID: operationID,
                    message: String(localized: "Sending wake request…")
                )
            )

        case .succeeded(let operationID):
            noticeHost.show(successNotice(operationID: operationID))

        case .failed(let operationID, let failure):
            let noticeID = operationID.uuidString
            noticeHost.show(
                NoticeItem(
                    id: noticeID,
                    lane: .bottomOperation,
                    level: .error,
                    leading: .icon("xmark.octagon.fill"),
                    title: String(localized: "Wake-on-LAN"),
                    message: failure.message,
                    dismissAction: {
                        noticeHost.dismiss(id: noticeID)
                        coordinator.dismissOutcome(operationID: operationID)
                    }
                )
            )
        }
    }

    private func operationNotice(
        operationID: UUID,
        message: String
    ) -> NoticeItem {
        NoticeItem(
            id: operationID.uuidString,
            lane: .bottomOperation,
            level: .info,
            leading: .activity,
            title: String(localized: "Wake-on-LAN"),
            message: message,
            action: NoticeAction(
                id: "cancel",
                title: String(localized: "Cancel"),
                role: .cancel,
                handler: {
                    coordinator.cancel(operationID: operationID)
                }
            )
        )
    }

    private func successNotice(operationID: UUID) -> NoticeItem {
        NoticeItem(
            id: operationID.uuidString,
            lane: .bottomOperation,
            level: .success,
            leading: .icon("checkmark.circle.fill"),
            title: String(localized: "Wake-on-LAN"),
            message: String(localized: "Wake request sent."),
            lifetime: .autoDismiss(.seconds(3))
        )
    }
}

private extension ServerWakeFailure {
    var message: String {
        switch self {
        case .notConfigured:
            return String(localized: "Enable Wake-on-LAN in Server Settings first.")
        case .unexpected:
            return String(localized: "VVTerm could not complete the wake request.")
        case .send(let error):
            return error.message
        }
    }
}

private extension WakeOnLANSendError {
    var message: String {
        switch self {
        case .localNetworkAccessDenied:
            return String(
                localized: "Allow Local Network access for VVTerm in System Settings. On iPhone and iPad, the build also needs Apple's multicast networking entitlement."
            )
        case .noEligibleNetworkInterface:
            return String(
                localized: "No active Wi-Fi or Ethernet IPv4 interface can send this wake request."
            )
        case .interfaceEnumerationFailed:
            return String(localized: "VVTerm could not read the active network interfaces.")
        case .socketCreationFailed:
            return String(localized: "VVTerm could not create the UDP socket.")
        case .broadcastConfigurationFailed:
            return String(localized: "VVTerm could not enable UDP broadcast on this device.")
        case .destinationEncodingFailed:
            return String(localized: "VVTerm could not prepare the network broadcast address.")
        case .datagramSendFailed:
            return String(
                localized: "VVTerm could not send the wake request. Check Local Network access."
            )
        case .incompleteDatagram:
            return String(localized: "The network did not accept the complete wake request.")
        }
    }
}
