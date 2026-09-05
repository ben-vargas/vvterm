# Shared UI and Apple Platform Rules

These rules also apply to feature UI that uses shared presentation.

## Platform Structure

- Prefer native Apple UI. Keep shared `Type.swift` focused on neutral contracts and state; put differing layout, lifecycle, modifiers, or adapters in `Type+iOS.swift` and `Type+macOS.swift`.
- The app has one multiplatform target. Use file-level `#if os(...)` gates; a folder or filename alone does not limit target membership.
- Keep platform-specific stored view state in platform child views or small platform models, not long-term gated `@State` in shared shells.
- Small inline platform gates are acceptable for constants or narrow modifiers, not whole layout or lifecycle variants.
- Use neutral product UI type names. Platform prefixes are appropriate for true UIKit/AppKit adapters and app-shell bridges.
- Preserve established navigation: macOS split navigation and toolbar tabs; iOS stack navigation, full-screen terminal, and sheets.

## Presentation

- Never apply glass to terminal content. Use existing adaptive glass helpers for supported controls and preserve supported-OS fallbacks.
- Keep blocking states local to their screen.
- Use `Core/UI/Notices` for shared non-blocking presentation: one top banner for persistent or degraded state and ID-keyed bottom operations for user-initiated progress or failure.
- Scope notice hosts to the app or feature surface. Do not add a global toast bus or move feature policy into Core UI.
- Keep destructive decisions in native alerts and confirmation dialogs.
