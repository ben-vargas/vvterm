import Foundation
import MoshBootstrap
import os

actor RemoteMoshManager {
    static let shared = RemoteMoshManager()
    private let logger = Logger(subsystem: "app.vivy.VivyTerm", category: "mosh-bootstrap")
    private static let installSuccessMarker = "__VVTERM_MOSH_INSTALLED__"
    private let availabilityTimeout: Duration = .seconds(8)
    private let bootstrapTimeout: Duration = .seconds(25)
    private let installTimeout: Duration = .seconds(180)

    private init() {}

    func isMoshServerAvailable(using client: SSHClient) async -> Bool {
        let okMarker = "__VVTERM_MOSH_OK__"
        let body = "\(RemoteTerminalBootstrap.shellPathExport()); if command -v mosh-server >/dev/null 2>&1; then printf '\(okMarker)'; else printf '__VVTERM_MOSH_NO__'; fi"
        let command = "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
        let output = try? await client.execute(command, timeout: availabilityTimeout)
        return output?.contains(okMarker) == true
    }

    func bootstrapConnectInfo(
        using client: SSHClient,
        startCommand: String?,
        portRange: ClosedRange<Int> = 60001...61000
    ) async throws -> MoshServerConnectInfo {
        let resolvedStartup = RemoteTerminalBootstrap.moshStartupScript(startCommand: startCommand)
        let quotedStartup = RemoteTerminalBootstrap.shellQuoted(resolvedStartup)
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        \(utf8LocaleExportScript());
        mosh-server new -s -c 256 -p \(portRange.lowerBound):\(portRange.upperBound) -- /bin/sh -lc \(quotedStartup) 2>&1
        """
        let command = "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
        logger.info("Mosh bootstrap startup: \(resolvedStartup.prefix(300))")
        let output = try await client.execute(command, timeout: bootstrapTimeout)
        return try parseConnectInfo(from: output)
    }

    func installMoshServer(using client: SSHClient) async throws {
        let command = "sh -lc \(RemoteTerminalBootstrap.shellQuoted(installScript()))"
        let output = try await client.execute(command, timeout: installTimeout)
        guard output.contains(Self.installSuccessMarker) else {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw SSHError.moshBootstrapFailed("mosh-server installation failed")
            }
            throw SSHError.moshBootstrapFailed(trimmed)
        }
    }

    nonisolated func parseConnectInfo(from output: String) throws -> MoshServerConnectInfo {
        do {
            return try MoshServerOutputParser.parse(output)
        } catch let error as MoshBootstrapError {
            throw mapBootstrapError(error, output: output)
        } catch {
            throw SSHError.moshBootstrapFailed(error.localizedDescription)
        }
    }

    nonisolated func mapBootstrapError(_ error: MoshBootstrapError, output: String? = nil) -> SSHError {
        switch error {
        case .missingServer:
            return .moshServerMissing
        case .permissionDenied:
            return .moshBootstrapFailed("Permission denied while starting mosh-server")
        case .invalidConnectLine:
            if let output, !output.isEmpty {
                return .moshBootstrapFailed("Invalid mosh-server response: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return .moshBootstrapFailed("Invalid mosh-server response")
        case .invalidPort:
            return .moshBootstrapFailed("mosh-server returned an invalid port")
        case .invalidKey:
            return .moshBootstrapFailed("mosh-server returned an invalid session key")
        case .processExited:
            return .moshBootstrapFailed("mosh-server exited before session startup completed")
        case .timedOut:
            return .moshBootstrapFailed("Timed out waiting for mosh-server startup")
        }
    }

    nonisolated func installScript() -> String {
        """
        \(RemoteTerminalBootstrap.shellPathExport());
        if command -v mosh-server >/dev/null 2>&1; then printf '\(Self.installSuccessMarker)'; exit 0; fi;
        if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else SUDO=""; fi;
        OS_NAME="$(uname -s)";
        if [ "$OS_NAME" = "Darwin" ]; then
          if command -v brew >/dev/null 2>&1; then
            brew install mosh;
          elif command -v port >/dev/null 2>&1; then
            $SUDO port install mosh;
          else
            echo "No supported package manager found for macOS.";
          fi;
        elif [ "$OS_NAME" = "Linux" ]; then
          if command -v apt-get >/dev/null 2>&1; then
            $SUDO apt-get update && $SUDO apt-get install -y mosh;
          elif command -v dnf >/dev/null 2>&1; then
            $SUDO dnf install -y mosh;
          elif command -v yum >/dev/null 2>&1; then
            $SUDO yum install -y mosh;
          elif command -v pacman >/dev/null 2>&1; then
            $SUDO pacman -Sy --noconfirm mosh;
          elif command -v apk >/dev/null 2>&1; then
            $SUDO apk add mosh;
          elif command -v zypper >/dev/null 2>&1; then
            $SUDO zypper -n install mosh;
          elif command -v xbps-install >/dev/null 2>&1; then
            $SUDO xbps-install -Sy mosh;
          elif command -v opkg >/dev/null 2>&1; then
            $SUDO opkg update && $SUDO opkg install mosh;
          elif command -v emerge >/dev/null 2>&1; then
            $SUDO emerge net-misc/mosh;
          elif command -v pkg >/dev/null 2>&1; then
            $SUDO pkg install -y mosh;
          else
            echo "No supported package manager found for Linux.";
          fi;
        else
          echo "Unsupported OS: $OS_NAME";
        fi;
        if command -v mosh-server >/dev/null 2>&1; then printf '\(Self.installSuccessMarker)'; else printf '__VVTERM_MOSH_INSTALL_FAILED__'; fi
        """
    }

    nonisolated func utf8LocaleExportScript() -> String {
        """
        VVTERM_UTF8_LOCALE="";
        if command -v locale >/dev/null 2>&1; then
          VVTERM_UTF8_LOCALE="$(locale -a 2>/dev/null | awk 'BEGIN { IGNORECASE = 1 } /^(C\\\\.UTF-8|C\\\\.utf8|en_US\\\\.UTF-8|en_US\\\\.utf8|UTF-8|utf8)$/ { print; exit }')";
        fi;
        if [ -z "$VVTERM_UTF8_LOCALE" ]; then VVTERM_UTF8_LOCALE="C.UTF-8"; fi;
        export LANG="$VVTERM_UTF8_LOCALE";
        export LC_ALL="$VVTERM_UTF8_LOCALE";
        export LC_CTYPE="$VVTERM_UTF8_LOCALE"
        """
    }
}
