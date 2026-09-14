# VVTerm

[![macOS](https://img.shields.io/badge/macOS-13.3+-black?style=flat-square&logo=apple)](https://vvterm.com)
[![iOS](https://img.shields.io/badge/iOS-16.1+-black?style=flat-square&logo=apple)](https://vvterm.com)
[![Swift](https://img.shields.io/badge/Swift-5.0+-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![Source License](https://img.shields.io/badge/Source-GPL%203.0-blue?style=flat-square)](LICENSE)
[![Binary License](https://img.shields.io/badge/Binary-App%20Store%20EULA-6e7681?style=flat-square)](LICENSE-APPSTORE.md)
[![Sponsor](https://img.shields.io/badge/Sponsor-GitHub-ff69b4?style=flat-square&logo=github)](https://github.com/sponsors/vivy-company)

Your servers. Everywhere.

![VVTerm macOS](/web/src/preview.png)

## Overview

VVTerm is a cross-platform SSH terminal app for Apple platforms. The current codebase targets iOS and macOS, uses Ghostty for terminal rendering, libssh2/OpenSSL for SSH transport, CloudKit for sync, and Keychain for local credential storage.

## Current State

- Main app target: `VVTerm`
- Companion target: `VVTermLiveActivity`
- Runtime targets: `macOS 13.3+` and `iOS 16.1+`
- Hardware targets: Apple Silicon / arm64 only
- App-owned code is organized under `VVTerm/App`, `VVTerm/Core`, and `VVTerm/Features`
- The repo also contains tests, native vendor builds, and the marketing site under `web/`

## Implemented Feature Areas

### Terminal and connections

- GPU-accelerated terminal rendering via `GhosttyKit`
- SSH authentication with password, SSH key, and SSH key + passphrase
- Connection modes for standard SSH, Tailscale, Mosh, Eternal Terminal, and Cloudflare Access
- Multi-session connection management with tabs, split panes, reconnect handling, and persisted session state
- tmux-aware startup, attach, install, and recovery flows
- Rich paste and clipboard helpers for terminal input
- iOS keyboard accessory support, including special keys and custom actions
- iOS Live Activity status for active terminal connections

Eternal Terminal connections use the configured SSH authentication and SSH port to run `etterminal`, then connect to `etserver` on TCP port `2022` by default. Install Eternal Terminal on the host and allow inbound traffic to the configured ET port. VVTerm's working-directory and optional tmux startup, attach, installation, and cleanup behavior also applies to ET sessions.

### Terminal notifications and progress tests

VVTerm uses libghostty for OSC 9 and OSC 777 notifications and OSC 9;4 progress.
Each pane shows Ghostty's two-point progress bar at its top edge. Paused progress
is orange, errors are red, and unknown progress moves. A remove report clears the
bar immediately; a quiet bar expires after 15 seconds. Progress is not saved.
Enable notification permission under **Settings → Sessions & Connections →
Notifications**. Turning the switch off stops new terminal notifications in VVTerm. System permission
is also required. Denied permission does not affect terminal output.
Clicking a notification opens its existing terminal tab and focuses its source
pane, after any required unlock. Notifications for closed panes open the app without starting a new connection;
on iPhone, they return to the server list.

Run this script in a VVTerm terminal, or copy it to the remote host first:

```sh
./scripts/test_terminal_events.sh
./scripts/test_terminal_events.sh progress --delay 5
./scripts/test_terminal_events.sh notify
./scripts/test_terminal_events.sh clear
./scripts/test_terminal_events.sh environment
```

Repeat the progress test in separate panes, switch tabs while it runs, and replace
or close a pane. The bar must remain local to its pane and must not resize terminal
rows or move the keyboard. For tmux, use `--tmux-depth 1` (or `2` for two nested
layers). Each layer must permit passthrough. The script does not change tmux
settings. It prints help with `--help`.

SSH and Eternal Terminal carry these events. Mosh currently does not; VVTerm
uses conservative terminal identity over Mosh. Local notifications require the
app to receive terminal output. They do not provide remote push delivery while
iOS has suspended VVTerm. Existing processes inside tmux keep their inherited
environment; the current transport policy applies to newly started processes in
VVTerm-managed sessions. External sessions are not reconfigured.

Automated checks:

```sh
python3 scripts/tests/terminal_events_test.py
python3 scripts/tests/terminal_tmux_test.py
python3 scripts/tests/terminal_mosh_test.py
xcodebuild test -project VVTerm.xcodeproj -scheme VVTerm \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -only-testing:VVTermTests/TerminalProgressStoreTests \
  -only-testing:VVTermTests/GhosttyTerminalEventsTests \
  -only-testing:VVTermTests/TerminalNotificationNavigationStoreTests \
  -only-testing:VVTermTests/RemoteTerminalBootstrapTests \
  -only-testing:VVTermTests/RemoteTmuxUnixCommandBuilderTests \
  -only-testing:VVTermUITests/TerminalEventsUITests
```

For iOS, use the same command with `-destination 'platform=iOS Simulator,id=UUID'`.
Also add `-only-testing:VVTermTests/TerminalPanePresentationTests` to check that
old view cleanup cannot pause a pane after it moves to a new view.
Get available IDs with `xcrun simctl list devices available`. Run once on an iPhone
and once on an iPad. The UI suite hosts real libghostty panes, sends actual OSC
bytes, and saves screenshots. Notification assertions use a test client; they do
not prove that system notification banners are permitted. Use the manual `notify`
command to check native banners. The tmux suite creates and removes isolated
local servers, and skips if tmux is absent. The Mosh check uses a temporary local
server and client to verify that unsupported OSC messages do not become visible
text; it skips if either Mosh command is absent.

### Servers and organization

- Workspaces with ordering, colors, and environment grouping
- Server metadata including favorites, tags, notes, last-connected timestamps, and biometric-unlock requirements
- Pro limit enforcement for workspaces, servers, tabs, and split panes
- Local-network SSH discovery via Bonjour and subnet probing

### Remote files

- SFTP-backed remote file browser for iOS and macOS
- Directory browsing with breadcrumbs, sorting, hidden-file toggles, and persisted browser state
- File preview, upload, download, export/share, new folder, rename, move, and delete flows
- Permission editing and remote-file conflict resolution

### Security and sync

- Keychain-backed storage for SSH credentials and Cloudflare service tokens
- CloudKit sync for servers, workspaces, terminal theme preferences, and terminal accessory profile data
- Full-app lock and per-server biometric unlock
- Privacy-mode support

### Customization and productivity

- Built-in and custom terminal themes with validation, storage-path management, and sync-aware preference handling
- Customizable terminal accessory bar with reorderable actions and user-defined shortcuts
- Terminal presets for saved commands/snippets
- Settings surfaces for general, terminal, sync, keychain, pro, and about flows
- Welcome/onboarding and in-app support surfaces

### Stats and voice input

- Remote server stats collection with live CPU and memory history
- On-device voice-to-command pipeline with MLX model management and Apple Speech fallback

## Architecture

VVTerm uses a feature-first structure for app-owned code.

```text
VVTerm/
├── App/                         # App entry, composition roots, shared root containers
├── Core/                        # Shared infrastructure and cross-feature primitives
│   ├── Logging/
│   ├── Network/
│   ├── Security/
│   ├── SSH/
│   ├── Sync/
│   ├── Terminal/                 # Includes the shared Ghostty bridge
│   └── UI/
├── Features/                    # Product features
│   ├── ConnectionViews/
│   ├── LocalDiscovery/
│   ├── RemoteFiles/
│   ├── Security/
│   ├── Servers/
│   ├── Settings/
│   ├── Stats/
│   ├── Store/
│   ├── Support/
│   ├── TerminalAccessories/
│   ├── TerminalPresets/
│   ├── TerminalSessions/         # Includes Ghostty runtime and platform UI
│   ├── TerminalThemes/
│   ├── VoiceInput/
│   └── Welcome/
└── Resources/                   # Bundled assets, themes, terminfo, localizations
```

Feature modules follow these boundaries:

- `Domain`: pure types and rules
- `Application`: state, orchestration, coordinators, managers
- `Infrastructure`: persistence, transport, adapters, external integrations
- `UI`: SwiftUI/AppKit/UIKit presentation

Other top-level folders in the repo:

```text
VVTerm-iOS/                     # iOS Info.plist and entitlements
VVTerm-macOS/                   # macOS Info.plist and entitlements
VVTermLiveActivity/             # ActivityKit target
VVTermShared/                   # Shared Activity attributes and small shared types
VVTermTests/                    # Unit and integration tests
VVTermUITests/                  # UI tests
Vendor/                         # Vendored native dependencies
scripts/                        # Vendor build scripts
web/                            # Astro site for vvterm.com
```

## Requirements

- Apple Silicon Mac for development
- Xcode `16.0+`
- macOS `13.3+`
- iOS `16.1+`
- `zig` and `cmake`

Install the non-Xcode build tools with Homebrew:

```bash
brew install zig cmake
```

## Building From Source

```bash
git clone https://github.com/vivy-company/vvterm.git
cd vvterm

# Build native vendor libraries (GhosttyKit + libssh2/OpenSSL)
./scripts/build.sh all

# Open the project in Xcode
open VVTerm.xcodeproj
```

`./scripts/build.sh` supports `all`, `ghostty`, `ssh`, `clean`, and `help`.

## Dependencies

Native/vendor dependencies:

- [libghostty](https://github.com/ghostty-org/ghostty) for terminal emulation and rendering
- [libssh2](https://github.com/libssh2/libssh2) for SSH transport
- [OpenSSL](https://github.com/openssl/openssl) for cryptography

Swift package dependencies currently resolved by the Xcode project:

- [Cloudflared](https://github.com/wiedymi/swift-cloudflared)
- [swift-mosh](https://github.com/wiedymi/swift-mosh)
- [swift-et](https://github.com/wiedymi/swift-et)
- [mlx-swift](https://github.com/ml-explore/mlx-swift)
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)
- [swift-numerics](https://github.com/apple/swift-numerics)
- [TweetNacl](https://github.com/bitmark-inc/tweetnacl-swiftwrap.git)

## Installation

[![Download on the App Store](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg)](https://apps.apple.com/app/vvterm/id6757482822)

## Pro Tier

| Feature | Free | Pro |
|---------|------|-----|
| Workspaces | 1 | Unlimited |
| Servers | 1 | Unlimited |
| Tabs | 1 | Unlimited |
| Split panes | No | Yes |

**Pricing:** Monthly ($6.49), Yearly ($24.99), Lifetime ($49.99)

## Documentation

- [CONTRIBUTING.md](CONTRIBUTING.md) for contribution workflow
- [SECURITY.md](SECURITY.md) for vulnerability reporting
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party notices
- [CLA.md](CLA.md) for the contributor license agreement

## License

VVTerm uses a dual-license model:

- Source code in this repository is licensed under GNU GPL v3.0 (`LICENSE`)
- Official App Store binaries are distributed under VVTerm's custom App Store EULA (`LICENSE-APPSTORE.md`, https://vvterm.com/terms)

If you obtain VVTerm from source and build it yourself, GPL-3.0 applies.
If you obtain VVTerm via the App Store, App Store distribution terms apply to that binary.

Copyright © 2026 Vivy Technologies Co., Limited
