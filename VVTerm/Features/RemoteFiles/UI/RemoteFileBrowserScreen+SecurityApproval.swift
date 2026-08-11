import SwiftUI

extension RemoteFileBrowserScreen {
    func securityApprovalPresentation<Content: View>(_ content: Content) -> some View {
        content
            .sshHostKeyTrustAlert(
                request: effectiveSecurityApprovalRequest,
                isPresented: hostKeyApprovalBinding,
                onCancel: { _ in cancelSecurityApproval() },
                onApprove: { _ in approveHostKeyAndRetry() }
            )
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

    var hostKeyApprovalChallenge: KnownHostsManager.Challenge? {
        guard case .hostKey(let challenge) = effectiveSecurityApprovalRequest else {
            return nil
        }
        return challenge
    }

    var effectiveSecurityApprovalRequest: ServerSecurityApprovalRequest? {
        securityApprovalRequest ?? uploadRuntime.securityApprovalRequest
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
        guard effectiveSecurityApprovalRequest == nil else { return false }

        let request = browser.securityApprovalActions.pendingRequest(error, server)

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
        if browser.securityApprovalActions.pendingRequest(error, server) != nil {
            return true
        }
        switch RemoteFileBrowserError.map(error) {
        case .hostKeyApprovalRequired:
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
        if securityApprovalRequest == nil, uploadRuntime.securityApprovalRequest != nil {
            uploadRuntime.cancelSecurityRequest()
            return
        }
        guard let request = securityApprovalRequest else { return }
        browser.securityApprovalActions.reject(request)
        let cancellation = securityApprovalCancellation
        clearSecurityApproval()
        operationErrorMessage = ServerSecurityApprovalError.cancelled.localizedDescription
        cancellation?()
    }

    @MainActor
    func approveHostKeyAndRetry() {
        if securityApprovalRequest == nil, uploadRuntime.securityApprovalRequest != nil {
            uploadRuntime.approveSecurityRequest()
            return
        }
        guard let request = securityApprovalRequest else { return }
        guard browser.securityApprovalActions.approve(request) else {
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
