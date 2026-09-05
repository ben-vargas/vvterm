# Shared Infrastructure

Keep Core contracts neutral. Feature policies and feature-owned models belong in Features; map them at infrastructure boundaries.

Read the applicable owner rules before editing:

- [SSH](SSH/AGENTS.md): transport, environment detection, startup, and remote session helpers.
- [Security](Security/AGENTS.md): Keychain, device identity, and privacy infrastructure.
- [Sync](Sync/AGENTS.md): CloudKit infrastructure.
- [Terminal](Terminal/AGENTS.md): shared terminal helpers and libghostty bridge.
- [UI](UI/AGENTS.md): shared presentation and Apple platform rules, including their use by features.

Other shared owners: `Network` handles connectivity and Cloudflare transport; `Logging` handles shared logging. Do not move feature workflows into either owner for convenience.
