# Remote Files

- Own file browsing, preview, transfer, and SFTP integration in this feature.
- UI renders state and forwards intents; keep path policy, transfer workflows, and all other non-view logic outside UI.
- Inject dependencies at the feature boundary. Keep file-browser policy out of `SSHClient`.
- Use direct cutovers, not compatibility shims or hidden live dependencies.
- Read [SSH rules](../../Core/SSH/AGENTS.md) when changing shared transport or remote command behavior.
