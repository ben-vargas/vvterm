import SwiftUI

extension RemoteFileBrowserScreen {
    func securityApprovalPresentation<Content: View>(_ content: Content) -> some View {
        content
            .alert(
                credentialApprovalPresentation.title,
                isPresented: credentialApprovalBinding
            ) {
                Button("Cancel", role: .cancel) {
                    cancelSecurityApproval()
                }
                Button(credentialApprovalPresentation.approvalButtonTitle) {
                    approveCredentialEndpointAndRetry()
                }
            } message: {
                Text(credentialApprovalPresentation.message)
            }
            .alert(
                hostKeyApprovalPresentation?.title ?? String(localized: "Trust SSH Host?"),
                isPresented: hostKeyApprovalBinding
            ) {
                Button("Cancel", role: .cancel) {
                    cancelSecurityApproval()
                }
                if hostKeyApprovalPresentation?.isDestructive == false {
                    Button(hostKeyApprovalPresentation?.approvalButtonTitle ?? String(localized: "Trust and Reconnect")) {
                        approveHostKeyAndRetry()
                    }
                } else {
                    Button(
                        hostKeyApprovalPresentation?.approvalButtonTitle ?? String(localized: "Replace and Reconnect"),
                        role: .destructive
                    ) {
                        approveHostKeyAndRetry()
                    }
                }
            } message: {
                Text(hostKeyApprovalPresentation?.message ?? "")
            }
    }

    func remoteOperationErrorMessage(for error: Error) -> String {
        RemoteFileBrowserError.map(error).errorDescription ?? error.localizedDescription
    }

    @MainActor
    func presentOperationError(
        _ error: Error,
        retry: (@MainActor () -> Void)? = nil,
        onCancellation: (@MainActor () -> Void)? = nil
    ) {
        if presentSecurityApproval(
            for: error,
            retry: retry,
            onCancellation: onCancellation
        ) {
            return
        }
        operationErrorMessage = remoteOperationErrorMessage(for: error)
    }

    var credentialApprovalPresentation: ServerCredentialApprovalPresentation {
        ServerCredentialApprovalPresentation(server: server)
    }

    var credentialApprovalBinding: Binding<Bool> {
        Binding(
            get: {
                guard case .credentialEndpoint(let serverID) = securityApprovalRequest else {
                    return false
                }
                return serverID == server.id
            },
            set: { _ in }
        )
    }

    var hostKeyApprovalChallenge: KnownHostsManager.Challenge? {
        guard case .hostKey(let challenge) = securityApprovalRequest else {
            return nil
        }
        return challenge
    }

    var hostKeyApprovalPresentation: SSHHostKeyTrustPresentation? {
        hostKeyApprovalChallenge.map(SSHHostKeyTrustPresentation.init)
    }

    var hostKeyApprovalBinding: Binding<Bool> {
        Binding(get: { hostKeyApprovalChallenge != nil }, set: { _ in })
    }

    @discardableResult
    @MainActor
    func presentSecurityApproval(
        for error: Error,
        retry: (@MainActor () -> Void)?,
        onCancellation: (@MainActor () -> Void)? = nil
    ) -> Bool {
        guard securityApprovalRequest == nil else { return false }

        let request: ServerSecurityApprovalRequest?
        if let detected = ServerSecurityApprovalRequest.detect(error, server: server) {
            request = detected
        } else {
            switch RemoteFileBrowserError.map(error) {
            case .credentialApprovalRequired:
                request = .credentialEndpoint(serverID: server.id)
            case .hostKeyApprovalRequired:
                request = KnownHostsManager.shared.pendingChallenge(
                    for: server.host,
                    port: server.port
                ).map(ServerSecurityApprovalRequest.hostKey)
            default:
                request = nil
            }
        }

        guard let request else {
            if case .hostKeyApprovalRequired = RemoteFileBrowserError.map(error) {
                operationErrorMessage = ServerSecurityApprovalError.unavailable.localizedDescription
                return true
            }
            return false
        }

        securityApprovalRetry = retry
        securityApprovalCancellation = onCancellation
        securityApprovalRequest = request
        return true
    }

    @MainActor
    func isSecurityApprovalError(_ error: Error) -> Bool {
        if ServerSecurityApprovalRequest.detect(error, server: server) != nil {
            return true
        }
        switch RemoteFileBrowserError.map(error) {
        case .credentialApprovalRequired, .hostKeyApprovalRequired:
            return true
        default:
            return false
        }
    }

    @MainActor
    func presentDirectorySecurityApprovalIfNeeded() {
        guard let error = browser.error(for: fileTab) else { return }
        _ = presentSecurityApproval(for: error, retry: {
            Task {
                await browser.refresh(server: server, tab: fileTab)
            }
        })
    }

    @MainActor
    func presentViewerSecurityApprovalIfNeeded() {
        guard let error = browser.viewerError(for: fileTab),
              let entry = snapshot.selectedEntry else { return }
        _ = presentSecurityApproval(for: error, retry: {
            Task {
                await browser.loadPreview(for: entry, in: fileTab, server: server)
            }
        })
    }

    @MainActor
    func cancelSecurityApproval() {
        guard let request = securityApprovalRequest else { return }
        if case .hostKey(let challenge) = request {
            KnownHostsManager.shared.reject(challenge)
        }
        let cancellation = securityApprovalCancellation
        clearSecurityApproval()
        operationErrorMessage = ServerSecurityApprovalError.cancelled.localizedDescription
        cancellation?()
    }

    @MainActor
    func approveCredentialEndpointAndRetry() {
        guard let request = securityApprovalRequest,
              case .credentialEndpoint(let serverID) = request,
              serverID == server.id else { return }

        Task {
            guard await appLockManager.authorizeProtectedServerAction(
                server,
                action: .approveCredentialEndpoint
            ) else {
                cancelSecurityApproval()
                return
            }

            do {
                try KeychainManager.shared.approveCredentialUse(for: server)
                completeSecurityApprovalAndRetry()
            } catch {
                clearSecurityApproval()
                operationErrorMessage = ServerSecurityApprovalError.unavailable.localizedDescription
            }
        }
    }

    @MainActor
    func approveHostKeyAndRetry() {
        guard let challenge = hostKeyApprovalChallenge else { return }
        guard KnownHostsManager.shared.approve(challenge) else {
            clearSecurityApproval()
            operationErrorMessage = ServerSecurityApprovalError.expired.localizedDescription
            return
        }
        completeSecurityApprovalAndRetry()
    }

    @MainActor
    func completeSecurityApprovalAndRetry() {
        let retry = securityApprovalRetry
        clearSecurityApproval()
        retry?()
    }

    @MainActor
    func clearSecurityApproval() {
        securityApprovalRequest = nil
        securityApprovalRetry = nil
        securityApprovalCancellation = nil
    }
}
