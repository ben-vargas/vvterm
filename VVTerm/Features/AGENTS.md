# Feature Ownership

Keep each feature's Domain, Application, Infrastructure, and UI boundaries intact. Shared neutral primitives belong in Core, not new app-wide bucket folders.

Read scoped rules for the owners involved in the task:

- [RemoteFiles](RemoteFiles/AGENTS.md): file browsing, preview, transfer, and SFTP integration.
- [Servers](Servers/AGENTS.md): server/workspace models, state, and management flows.
- [Stats](Stats/AGENTS.md): metrics collection and dashboard presentation.
- [Store](Store/AGENTS.md): entitlements, purchases, and upgrade surfaces.
- [TerminalSessions](TerminalSessions/AGENTS.md): sessions, tabs, terminal runtimes, and platform terminal UI.

Other feature boundaries:

- `ConnectionViews`: connection-view tab configuration types and state.
- `LocalDiscovery`: discovery-specific behavior and UI.
- `Security`: app lock and biometric flows; use Core Security for infrastructure.
- `Settings`: settings presentation and settings screens; feature owners retain their state and workflows.
- `Support`: support and contact UI.
- `TerminalAccessories`: keyboard accessory models, preferences, validation, and settings UI.
- `TerminalFonts`: custom terminal-font behavior and storage.
- `TerminalThemes`: theme models, validation, storage, parsing, and management.
- `VoiceInput`: audio capture, transcription, MLX model management, and transcription settings.
- `Welcome`: onboarding copy and presentation.

Do not create a scoped instruction file only to repeat parent rules. Add one when a feature has specific constraints that need to stay next to its code.
