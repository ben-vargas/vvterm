import Foundation

nonisolated enum WakeOnLANMACAddressResolutionError: Error, Equatable, Sendable {
    case unsupportedRemoteShell
    case addressNotFound
}

nonisolated enum RemoteWakeOnLANMACAddressDiscovery {
    static func command(
        for environment: RemoteEnvironment
    ) throws -> String {
        guard environment.platform == .windows else {
            return RemoteTerminalBootstrap.wrapPOSIXShellCommand(posixScript)
        }

        if environment.shellProfile.family == .powershell {
            return powerShellScript
        }
        guard let executable = environment.powerShellExecutable else {
            throw WakeOnLANMACAddressResolutionError.unsupportedRemoteShell
        }

        let wrapped = RemoteTerminalBootstrap.wrapPowerShellCommand(
            powerShellScript,
            executableName: executable
        )
        if environment.shellProfile.family == .cmd {
            return RemoteTerminalBootstrap.wrapCmdExecCommand(wrapped)
        }
        return wrapped
    }

    static func parse(_ output: String) throws -> WakeOnLANMACAddress {
        let punctuation = CharacterSet(charactersIn: "'\",;[]()")
        for token in output.split(whereSeparator: { $0.isWhitespace }) {
            let candidate = String(token).trimmingCharacters(in: punctuation)
            if let address = try? WakeOnLANMACAddress(candidate) {
                return address
            }
        }
        throw WakeOnLANMACAddressResolutionError.addressNotFound
    }

    private static let posixScript = #"""
    VVTERM_ADDRESS="$(printf '%s' "$SSH_CONNECTION" | awk '{print $3}')";
    VVTERM_ADDRESS="${VVTERM_ADDRESS%%%*}";
    [ -n "$VVTERM_ADDRESS" ] || exit 2;
    VVTERM_INTERFACE="";
    if command -v ip >/dev/null 2>&1; then
      VVTERM_INTERFACE="$(ip -o addr show 2>/dev/null | awk -v target="$VVTERM_ADDRESS" '{address=$4; sub(/\/.*/, "", address); interface=$2; sub(/@.*/, "", interface); if (address == target) {print interface; exit}}')";
    fi;
    if [ -z "$VVTERM_INTERFACE" ] && command -v ifconfig >/dev/null 2>&1; then
      VVTERM_INTERFACE="$(ifconfig -a 2>/dev/null | awk -v target="$VVTERM_ADDRESS" '/^[^[:space:]]/ {interface=$1; sub(/:$/, "", interface)} $1 == "inet" || $1 == "inet6" {address=$2; sub(/^addr:/, "", address); sub(/%.*/, "", address); if (address == target) {print interface; exit}}')";
    fi;
    [ -n "$VVTERM_INTERFACE" ] || exit 3;
    if [ -r "/sys/class/net/$VVTERM_INTERFACE/address" ]; then
      cat "/sys/class/net/$VVTERM_INTERFACE/address";
    elif command -v ip >/dev/null 2>&1; then
      ip link show dev "$VVTERM_INTERFACE" 2>/dev/null | awk '/link\/ether/ {print $2; exit}';
    elif command -v ifconfig >/dev/null 2>&1; then
      ifconfig "$VVTERM_INTERFACE" 2>/dev/null | awk '$1 == "ether" || $1 == "lladdr" {print $2; exit}';
    fi
    """#

    private static let powerShellScript = #"""
    $parts = @($env:SSH_CONNECTION -split '\s+' | Where-Object { $_ });
    if ($parts.Count -ge 3) {
      $address = ($parts[2] -split '%')[0];
      $adapter = Get-NetIPAddress -IPAddress $address -ErrorAction SilentlyContinue |
        ForEach-Object { Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue } |
        Where-Object { $_.MacAddress } |
        Select-Object -First 1;
      if ($adapter) { Write-Output $adapter.MacAddress }
    }
    """#
}

nonisolated struct SSHServerWakeOnLANMACAddressResolver: WakeOnLANMACAddressResolving {
    private let connectionOperations: any ServerConnectionOperationRunning

    init(connectionOperations: any ServerConnectionOperationRunning) {
        self.connectionOperations = connectionOperations
    }

    func resolveMACAddress(
        for server: Server,
        credentials: ServerCredentials
    ) async throws -> WakeOnLANMACAddress {
        let result = ResolvedWakeOnLANMACAddress()
        try await connectionOperations.runServerConnectionTest(
            server: server,
            credentials: credentials
        ) { client in
            try Task.checkCancellation()
            let environment = await client.remoteEnvironment()
            let command = try RemoteWakeOnLANMACAddressDiscovery.command(
                for: environment
            )
            let output = try await client.execute(command, timeout: .seconds(8))
            let address = try RemoteWakeOnLANMACAddressDiscovery.parse(output)
            await result.store(address)
        }
        try Task.checkCancellation()
        guard let address = await result.value else {
            throw WakeOnLANMACAddressResolutionError.addressNotFound
        }
        return address
    }
}

private actor ResolvedWakeOnLANMACAddress {
    private(set) var value: WakeOnLANMACAddress?

    func store(_ value: WakeOnLANMACAddress) {
        self.value = value
    }
}
