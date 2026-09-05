# App Composition

- Own app entry, root containers, localization preferences, and iOS/macOS app-shell navigation here.
- Create one explicit production dependency graph and inject it at app or feature roots.
- Keep composition owners plain and non-observable. They assemble dependencies, not duplicate feature state.
- Keep live, preview, and test assembly explicit; previews must not start external work.
- Split platform-specific composition and lifecycle into `Type+iOS.swift` and `Type+macOS.swift`, with file-level platform gates.
