# VVTerm

Cross-platform (iOS/macOS) SSH terminal app with iCloud sync and Keychain credential storage.

## Target Versions

- **macOS**: 13.3+ (Ventura), arm64 only
- **iOS**: 16.0+, arm64 only
- **Xcode**: 16.0+

## Architecture

```
VVTerm/
├── App/
├── Core/                         # Shared infrastructure and platform glue
│   ├── Network/
│   ├── SSH/
│   ├── Security/
│   └── Sync/
├── Features/                     # Feature-first architecture target
│   ├── ConnectionViews/
│   │   ├── Domain/
│   │   └── Application/
│   ├── LocalDiscovery/
│   │   ├── Domain/
│   │   ├── Application/
│   │   ├── Infrastructure/
│   │   └── UI/
│   ├── Servers/
│   │   ├── Domain/
│   │   ├── Application/
│   │   └── UI/
│   ├── RemoteFiles/
│   │   ├── Domain/
│   │   ├── Application/
│   │   ├── Infrastructure/
│   │   └── UI/
│   ├── Security/
│   │   ├── Domain/
│   │   ├── Application/
│   │   ├── Infrastructure/
│   │   └── UI/
│   ├── Store/
│   │   ├── Domain/
│   │   ├── Application/
│   │   └── UI/
│   ├── TerminalThemes/
│   │   ├── Domain/
│   │   ├── Application/
│   │   ├── Infrastructure/
│   │   └── UI/
│   ├── TerminalAccessories/
│   │   ├── Domain/
│   │   ├── Application/
│   │   └── UI/
│   ├── TerminalPresets/
│   │   ├── Domain/
│   │   ├── Application/
│   │   └── UI/
│   ├── TerminalSessions/
│   │   ├── Domain/
│   │   ├── Application/
│   │   └── UI/
│   ├── Stats/
│   │   ├── Domain/
│   │   ├── Application/
│   │   ├── Infrastructure/
│   │   └── UI/
│   └── Welcome/
│       ├── Domain/
│       └── UI/
├── GhosttyTerminal/              # libghostty terminal emulation
├── Models/                       # Legacy app-wide buckets, migrated over time
├── Managers/
├── Services/
└── Views/
```

## Architecture Direction

VVTerm is moving from app-wide technical buckets toward **feature-first architecture**.

Current migration status:
- `Core/Sync` is extracted for CloudKit sync infrastructure.
- `Core/Security` is extracted for keychain infrastructure.
- `Core/Network` is extracted for shared connectivity monitoring and Cloudflare transport support.
- `Core/SSH` is extracted for shared SSH bootstrap, known-hosts, key generation, environment detection, and rich-paste support.
- `Features/ConnectionViews` is migrated for connection view tab configuration types and state.
- `Features/RemoteFiles` is fully migrated and is the reference pattern for larger features.
- `Features/LocalDiscovery` is migrated for discovery-specific code and UI.
- `Features/Servers` is migrated for server/workspace domain models, server management, and server/workspace UI flows.
- `Features/Stats` is migrated for server metrics collection and presentation.
- `Features/Security` is migrated for app lock and biometric authentication flows.
- `Features/Store` is migrated for Pro entitlements, purchases, and upgrade surfaces.
- `Features/TerminalThemes` is migrated for theme models, validation, storage paths, parsing, and theme management.
- `Features/TerminalAccessories` is migrated for keyboard accessory models, preferences, settings UI, and accessory validation flows.
- `Features/TerminalPresets` is migrated for terminal preset models, persistence, and preset form UI.
- `Features/TerminalSessions` is migrated for terminal session/tab domain models, session/tab managers, tmux prompt coordination, live activity support, and terminal session UI.
- `Features/Welcome` is migrated for welcome/onboarding copy and presentation.
- Other areas may still live in legacy top-level buckets such as `Models`, `Managers`, `Services`, and `Views`.
- New work inside migrated features must stay inside their `Features/<FeatureName>` subtree and should not add code for those features back into the legacy structure.

Feature-first target shape:
- `Domain`: pure feature types and rules
- `Application`: feature state, orchestration, coordinators, use-case style logic
- `Infrastructure`: transport, persistence, adapters, external integrations
- `UI`: SwiftUI/AppKit/UIKit presentation only

For Files/SFTP specifically:
- no non-view logic under `UI`
- no feature policy inside `SSHClient` beyond low-level transport/session behavior
- use explicit dependency injection at the feature boundary
- do direct cutovers, not compatibility shims

For every migrated feature:
- keep `Domain`, `Application`, `Infrastructure`, and `UI` boundaries intact
- prefer view-owned dependencies to be injected from the app/screen boundary instead of created inside leaf views
- if shared cross-feature primitives are needed, extract them into `Core` instead of pushing them back into legacy buckets

## Refactoring Rules

When doing architectural refactors:
- prioritize structural splits and ownership cleanup over behavior changes
- preserve existing UI, UX, and visual behavior unless the user explicitly asks for a change
- do not bundle redesigns or new features into a refactor
- keep platform parity intact unless a platform-specific bug is being fixed
- if a behavior change is necessary for correctness or safety, keep it minimal and isolated

Safe refactor expectation:
- same screens
- same entry points
- same interactions
- same user-facing flows
- smaller files, clearer boundaries, better ownership

## Commits

- Use **atomic commits**.
- Each commit must represent one coherent change that can be reviewed and reverted independently.
- Do not mix architecture docs, code moves, behavioral fixes, and unrelated cleanup in one commit unless they are inseparable.
- Prefer a sequence such as:
  - architecture/spec update
  - domain extraction
  - application/store extraction
  - infrastructure extraction
  - UI split
  - targeted safety fix
- Before committing, verify the diff matches a single intent.

## Key Components

### Terminal
- Uses **libghostty** (Ghostty terminal emulator) via xcframework
- Metal GPU rendering (arm64 only)
- iOS keyboard toolbar with special keys (Esc, Tab, Ctrl, arrows)

### SSH
- **libssh2** + **OpenSSL** for SSH connections
- Auth methods: Password, SSH Key, Key+Passphrase
- Credentials stored in Keychain

### Data Sync
- **CloudKit** for server/workspace sync across devices
- Container: `iCloud.app.vivy.VivyTerm`
- Local fallback via UserDefaults

### Pro Tier (StoreKit 2)
- Free: 1 workspace, 3 servers, 1 tab
- Pro: Unlimited everything
- Products: Monthly ($6.49), Yearly ($19.99), Lifetime ($29.99)

## Build Dependencies

### libghostty
Pre-built xcframework at `Vendor/libghostty/GhosttyKit.xcframework`
Build with: `./scripts/build.sh ghostty`

### libssh2 + OpenSSL
Build with: `./scripts/build.sh ssh`
Output: `Vendor/libssh2/{macos,ios,ios-simulator}/`

## Data Models

### Server
```swift
struct Server: Identifiable, Codable {
    let id: UUID
    var workspaceId: UUID
    var environment: ServerEnvironment
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var keychainCredentialId: String
}
```

### Workspace
```swift
struct Workspace: Identifiable, Codable {
    let id: UUID
    var name: String
    var colorHex: String
    var environments: [ServerEnvironment]
    var order: Int
}
```

### ConnectionSession (local only, not synced)
```swift
struct ConnectionSession: Identifiable {
    let id: UUID
    let serverId: UUID
    var title: String
    var connectionState: ConnectionState
}
```

## UI Patterns

### macOS Layout
- NavigationSplitView with sidebar (workspaces/servers) and detail (terminal)
- Toolbar tabs for multiple connections
- `.windowToolbarStyle(.unified)`

### iOS Layout
- NavigationStack with server list
- Full-screen terminal with keyboard toolbar
- Sheet-based forms

### Liquid Glass (iOS 26+ / macOS 26+)
```swift
// Use adaptive helpers for backwards compatibility
.adaptiveGlass()           // Falls back to .ultraThinMaterial
.adaptiveGlassTint(.green) // For semantic tinting
```

## Important Notes

1. **Never apply glass to terminal content** - only navigation/toolbars
2. **Deduplicate by ID** when syncing from CloudKit
3. **Pro limits enforced in**: `ServerManager.canAddServer`, `canAddWorkspace`, `ConnectionSessionManager.canOpenNewTab`
4. **Keychain credentials** are NOT synced - only server metadata syncs via CloudKit
5. **iOS keyboard toolbar** provides Esc, Tab, Ctrl, arrows, function keys
6. **Voice-to-command** uses MLX Whisper/Parakeet on-device or Apple Speech fallback
