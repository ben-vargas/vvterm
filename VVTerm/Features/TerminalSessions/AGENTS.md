# Terminal Sessions

- Own session/tab models and state, remote-session coordination, live activities, runtime surfaces, and platform terminal screens here.
- Keep tab limits in the authoritative application state, not a second UI policy.
- Use shared Core Terminal contracts for clipboard, paste, and libghostty bridge behavior.
- Read [SSH rules](../../Core/SSH/AGENTS.md) for startup, shell, and multiplexer changes. Session orchestration must not create shell syntax or change saved preferences to match runtime fallback.
- Read [Apple UI rules](../../Core/UI/AGENTS.md) for platform presentation. Preserve the root keyboard/input regression coverage requirements.
