import Testing
@testable import VVTerm

struct SSHServerWakeOnLANMACAddressResolverTests {
    @Test
    func parserFindsAValidAddressInCommandOutput() throws {
        let address = try RemoteWakeOnLANMACAddressDiscovery.parse(
            "warning: ignored\nAA-BB-CC-DD-EE-FF\n"
        )

        #expect(address.canonicalValue == "AA:BB:CC:DD:EE:FF")
    }

    @Test
    func parserRejectsMissingOrNonUnicastAddresses() {
        for output in ["", "00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF"] {
            #expect(throws: WakeOnLANMACAddressResolutionError.addressNotFound) {
                try RemoteWakeOnLANMACAddressDiscovery.parse(output)
            }
        }
    }

    @Test
    func posixCommandUsesTheSSHConnectionInterface() throws {
        let environment = RemoteEnvironment(
            platform: .linux,
            shellProfile: .posix(shellName: "sh"),
            activeShellName: "sh",
            powerShellExecutable: nil
        )

        let command = try RemoteWakeOnLANMACAddressDiscovery.command(
            for: environment
        )

        #expect(command.contains("SSH_CONNECTION"))
        #expect(command.contains("/sys/class/net"))
        #expect(command.contains("ifconfig"))
    }

    @Test
    func windowsCommandUsesTheAdapterForTheSSHAddress() throws {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .powershell(executableName: "powershell"),
            activeShellName: "powershell",
            powerShellExecutable: "powershell"
        )

        let command = try RemoteWakeOnLANMACAddressDiscovery.command(
            for: environment
        )

        #expect(command.contains("SSH_CONNECTION"))
        #expect(command.contains("Get-NetIPAddress"))
        #expect(command.contains("Get-NetAdapter"))
    }

    @Test
    func windowsCommandRequiresPowerShellWhenTheLoginShellIsCmd() {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .cmd,
            activeShellName: "cmd.exe",
            powerShellExecutable: nil
        )

        #expect(throws: WakeOnLANMACAddressResolutionError.unsupportedRemoteShell) {
            try RemoteWakeOnLANMACAddressDiscovery.command(for: environment)
        }
    }
}
