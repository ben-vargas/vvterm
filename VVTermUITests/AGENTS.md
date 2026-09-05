# UI Tests

- Read the production owner's rules and the root keyboard/input regression policy before changing tests.
- Group tests by feature and platform. Name files `FlowUITests+iOS.swift` or `FlowUITests+macOS.swift`.
- Keep file-level `#if os(iOS)` or `#if os(macOS)` gates; folders and filenames do not limit this multiplatform test target.
- Keep feature-specific support beside its tests. Use shared Support only for helpers with real cross-feature users.
- Split suites only for independent behaviors or owners, not a line-count target.
- Preserve serialized execution, actor isolation, reset hooks, environment gates, and test identifiers during moves. Compare test inventory before and after a large reorganization.
- Do not bundle test moves with a test-framework migration, new product behavior, or unrelated coverage work.
