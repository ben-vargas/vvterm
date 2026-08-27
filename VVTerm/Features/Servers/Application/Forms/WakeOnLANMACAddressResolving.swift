nonisolated protocol WakeOnLANMACAddressResolving: Sendable {
    func resolveMACAddress(
        for server: Server,
        credentials: ServerCredentials
    ) async throws -> WakeOnLANMACAddress
}
