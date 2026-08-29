import Foundation
import Testing
@testable import VVTerm

struct RemoteSystemIdentityTests {
    @Test(arguments: [
        "MacBookPro18,3",
        "Mac13,1",
        "Mac14,13",
        "Macmini9,1",
        "Mac16,10",
        "iMac21,1",
        "MacPro7,1",
    ])
    func acceptsValidAppleHardwareModelIdentifiers(_ rawValue: String) {
        #expect(AppleHardwareModelIdentifier(rawValue: rawValue)?.rawValue == rawValue)
    }

    @Test(arguments: [
        "",
        "MacBookPro",
        "MacBookPro18",
        "MacBookPro18,",
        "MacBookPro18,3,1",
        "../MacBookPro18,3",
        "MacBookPro18,3\nother",
    ])
    func rejectsInvalidAppleHardwareModelIdentifiers(_ rawValue: String) {
        #expect(AppleHardwareModelIdentifier(rawValue: rawValue) == nil)
    }

    @Test
    func rejectsOversizedAppleHardwareModelIdentifier() {
        let rawValue = String(
            repeating: "M",
            count: AppleHardwareModelIdentifier.maximumByteCount - 2
        ) + "1,1"
        #expect(rawValue.utf8.count > AppleHardwareModelIdentifier.maximumByteCount)
        #expect(AppleHardwareModelIdentifier(rawValue: rawValue) == nil)
    }

    @Test
    func acceptsMaximumSizedAppleHardwareModelIdentifier() {
        let rawValue = String(
            repeating: "M",
            count: AppleHardwareModelIdentifier.maximumByteCount - 3
        ) + "1,1"

        #expect(rawValue.utf8.count == AppleHardwareModelIdentifier.maximumByteCount)
        #expect(AppleHardwareModelIdentifier(rawValue: rawValue)?.rawValue == rawValue)
    }

    @Test
    func mapsKnownAppleHardwareFamiliesAndKeepsUnknownOpen() throws {
        #expect(try #require(AppleHardwareModelIdentifier(rawValue: "MacBookPro18,3")).family == .macBook)
        #expect(try #require(AppleHardwareModelIdentifier(rawValue: "Macmini9,1")).family == .macMini)
        #expect(try #require(AppleHardwareModelIdentifier(rawValue: "Mac13,1")).family == .macStudio)
        #expect(try #require(AppleHardwareModelIdentifier(rawValue: "iMac21,1")).family == .iMac)
        #expect(try #require(AppleHardwareModelIdentifier(rawValue: "MacPro7,1")).family == .macPro)
        #expect(try #require(AppleHardwareModelIdentifier(rawValue: "FutureComputer1,1")).family == .unknown)
    }

    @Test
    func linuxParserUsesExactIdentifierInsteadOfFamilyHint() {
        let identity = RemoteSystemIdentityResolver.parseLinuxOSRelease(
            """
            ID=pop
            ID_LIKE="ubuntu debian"
            PRETTY_NAME="Pop!_OS 24.04"
            """
        )

        #expect(identity.kind == .linux)
        #expect(identity.displayName == "Pop!_OS 24.04")
    }

    @Test
    func identitySanitizesControlCharactersInDisplayName() {
        let identity = RemoteSystemIdentity(
            kind: .linux,
            displayName: "Linux\u{0007}Server"
        )
        #expect(identity.displayName == "Linux Server")
    }

    @Test
    func identityDecodingReappliesValidation() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "kind": "macos",
            "displayName": "  macOS\u{0007} Server  ",
            "appleHardwareModelIdentifier": "invalid model",
        ])

        let identity = try JSONDecoder().decode(RemoteSystemIdentity.self, from: data)

        #expect(identity.displayName == "macOS Server")
        #expect(identity.appleHardwareModelIdentifier == nil)
    }

    @Test
    func linuxParserMapsReviewedExactIdentifiers() {
        #expect(RemoteSystemIdentityResolver.parseLinuxOSRelease("ID=ubuntu").kind == .ubuntu)
        #expect(RemoteSystemIdentityResolver.parseLinuxOSRelease("ID=debian").kind == .debian)
        #expect(RemoteSystemIdentityResolver.parseLinuxOSRelease("ID=fedora").kind == .fedora)
        #expect(RemoteSystemIdentityResolver.parseLinuxOSRelease("ID=nixos").kind == .nixOS)
    }

    @Test
    func malformedOSReleaseFallsBackToGenericLinux() {
        let identity = RemoteSystemIdentityResolver.parseLinuxOSRelease(
            "ID=\"unterminated\nPRETTY_NAME=\"Valid Name\""
        )
        #expect(identity.kind == .linux)
        #expect(identity.displayName == "Valid Name")
    }

    @Test
    func linuxParserHandlesQuotedEscapedAndDuplicateValues() {
        let identity = RemoteSystemIdentityResolver.parseLinuxOSRelease(
            #"""
            ID="ubuntu"
            ID=debian
            PRETTY_NAME="Ubuntu \"Noble\" \\ LTS"
            """#
        )

        #expect(identity.kind == .ubuntu)
        #expect(identity.displayName == #"Ubuntu "Noble" \ LTS"#)
    }

    @Test
    func linuxParserHandlesMissingAndTruncatedValues() {
        let missing = RemoteSystemIdentityResolver.parseLinuxOSRelease("NAME=")
        let truncated = RemoteSystemIdentityResolver.parseLinuxOSRelease(
            "ID=ubuntu\nPRETTY_NAME=\"Ubuntu"
        )

        #expect(missing.kind == .linux)
        #expect(missing.displayName == nil)
        #expect(truncated.kind == .ubuntu)
        #expect(truncated.displayName == nil)
    }

    @Test
    func linuxDisplayTextAndProbeOutputAreBounded() {
        let identity = RemoteSystemIdentityResolver.parseLinuxOSRelease(
            "ID=unknown\nPRETTY_NAME=\"\(String(repeating: "A", count: 20_000))\""
        )

        #expect(identity.kind == .linux)
        #expect(identity.displayName?.utf8.count == 96)
        #expect(RemoteEnvironmentResolver.maximumProbeOutputBytes == 16 * 1_024)
    }

    @Test
    func parsesWindowsWorkstationAndServerCIMOutput() throws {
        let workstation = try #require(RemoteSystemIdentityResolver.parseWindowsCIMOutput(
            """
            __VVTERM_WINDOWS_CAPTION__=Microsoft Windows 11 Pro
            __VVTERM_WINDOWS_VERSION__=10.0.26100
            __VVTERM_WINDOWS_PRODUCT_TYPE__=1
            """
        ))
        let server = try #require(RemoteSystemIdentityResolver.parseWindowsCIMOutput(
            """
            __VVTERM_WINDOWS_CAPTION__=Microsoft Windows Server 2025
            __VVTERM_WINDOWS_VERSION__=10.0.26100
            __VVTERM_WINDOWS_PRODUCT_TYPE__=3
            """
        ))

        #expect(workstation.productType == 1)
        #expect(server.productType == 3)
        #expect(server.caption == "Microsoft Windows Server 2025")
    }

    @Test
    func safeProbeCommandsAreFixedAndNonInteractive() {
        let linuxCommand = RemoteSystemIdentityResolver.linuxOSReleaseCommand()
        #expect(linuxCommand.contains("/etc/os-release"))
        #expect(linuxCommand.contains("/usr/lib/os-release"))
        #expect(linuxCommand.contains("elif"))
        #expect(!linuxCommand.contains("source"))
        #expect(!linuxCommand.contains("sudo"))
        #expect(RemoteSystemIdentityResolver.appleHardwareModelCommand() == "/usr/sbin/sysctl -n hw.model")
        #expect(RemoteEnvironmentResolver.maximumProbeOutputBytes == 16 * 1_024)
    }

    @Test
    func windowsFallsBackToFixedCmdProbeWhenCIMIsUnavailable() async {
        let environment = RemoteEnvironment(
            platform: .windows,
            shellProfile: .powershell(executableName: "pwsh"),
            activeShellName: "pwsh",
            powerShellExecutable: "pwsh"
        )
        let commands = RemoteIdentityCommandRecorder()

        let identity = await RemoteSystemIdentityResolver.resolve(
            environment: environment,
            execute: { command, timeout in
                await commands.append(command)
                #expect(timeout == .seconds(2))
                return command == "cmd.exe /d /c ver"
                    ? "Microsoft Windows [Version 10.0.26100.0]"
                    : "invalid CIM output"
            }
        )

        #expect(identity == RemoteSystemIdentity(kind: .windows, displayName: "Windows"))
        #expect(await commands.values().last == "cmd.exe /d /c ver")
    }

    @Test
    func identityProbeCancellationReturnsNoIdentity() async {
        let gate = RemoteIdentityProbeGate()
        let environment = RemoteEnvironment(
            platform: .linux,
            shellProfile: .posix(shellName: "sh"),
            activeShellName: "sh",
            powerShellExecutable: nil
        )
        let task = Task {
            await RemoteSystemIdentityResolver.resolve(
                environment: environment,
                execute: { _, _ in
                    await gate.markStarted()
                    try await Task.sleep(for: .seconds(60))
                    return "ID=ubuntu"
                }
            )
        }

        await gate.waitUntilStarted()
        task.cancel()

        #expect(await task.value == nil)
    }
}

private actor RemoteIdentityCommandRecorder {
    private var commands: [String] = []

    func append(_ command: String) {
        commands.append(command)
    }

    func values() -> [String] {
        commands
    }
}

private actor RemoteIdentityProbeGate {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
