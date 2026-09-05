# SSH and Remote Sessions

- Own shared SSH transport, known hosts, authentication, environment detection, bootstrap, rich paste, and multiplexer/mosh helpers here.
- Keep file-browser and other feature policy out of `SSHClient`; it owns low-level transport and session behavior.
- Resolve platform and shell through `SSHClient.remoteEnvironment()`. Build startup and working-directory commands through `RemoteShellProfile` and `RemoteTerminalBootstrap`.
- UI and session orchestration must not construct POSIX, PowerShell, or `cmd.exe` syntax.
- Runtime capability fallback must not rewrite persisted transport or multiplexer preferences.
- Windows tmux-compatible sessions use the explicit psmux backend, not POSIX tmux command construction.
- Probe `psmux`, then `pmux`; accept `tmux.exe` only after a psmux-specific compatibility check.
- Apply VVTerm-created tmux or psmux configuration only to VVTerm-managed sessions, never external user sessions.
