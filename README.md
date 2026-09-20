# VVTerm

[![macOS](https://img.shields.io/badge/macOS-13.3+-black?style=flat-square&logo=apple)](https://vvterm.com)
[![iOS](https://img.shields.io/badge/iOS-16.1+-black?style=flat-square&logo=apple)](https://vvterm.com)
[![Swift](https://img.shields.io/badge/Swift-6.0+-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![Source License](https://img.shields.io/badge/Source-GPL%203.0-blue?style=flat-square)](LICENSE)
[![Binary License](https://img.shields.io/badge/Binary-App%20Store%20EULA-6e7681?style=flat-square)](LICENSE-APPSTORE.md)
[![Sponsor](https://img.shields.io/badge/Sponsor-GitHub-ff69b4?style=flat-square&logo=github)](https://github.com/sponsors/vivy-company)

Your servers. Everywhere.

![VVTerm macOS](/web/src/preview.png)

VVTerm is an SSH terminal app for iOS and macOS. It uses Ghostty for terminal rendering, libssh2 and OpenSSL for SSH transport, CloudKit for sync, and Keychain for local credential storage.

## Installation

[![Download on the App Store](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg)](https://apps.apple.com/app/vvterm/id6757482822)

## Requirements

- Apple Silicon Mac
- Xcode 16.0 or later
- macOS 13.3 or later
- iOS 16.1 or later
- Zig and CMake

Install the command-line build tools with Homebrew:

```sh
brew install zig cmake
```

## Build From Source

```sh
git clone https://github.com/vivy-company/vvterm.git
cd vvterm
./scripts/build.sh all
open VVTerm.xcodeproj
```

The build script supports `all`, `ghostty`, `ssh`, `verify`, `clean`, and `help`.

## Project Structure

```text
VVTerm/
├── App/                 # App entry and dependency composition
├── Core/                # Shared infrastructure
├── Features/            # Product features
└── Resources/           # Assets, themes, terminfo, and localizations

VVTerm-iOS/              # iOS configuration
VVTerm-macOS/            # macOS configuration
VVTermLiveActivity/      # ActivityKit target
VVTermShared/            # Types shared with the ActivityKit target
VVTermTests/             # Unit and integration tests
VVTermUITests/           # UI tests
Vendor/                  # Native dependencies
scripts/                 # Build and validation scripts
web/                     # Website for vvterm.com
```

Feature code uses four boundaries:

- `Domain` for pure types and rules
- `Application` for state and workflows
- `Infrastructure` for persistence, transport, and adapters
- `UI` for SwiftUI, AppKit, and UIKit presentation

## Main Dependencies

- [libghostty](https://github.com/ghostty-org/ghostty) for terminal emulation and rendering
- [libssh2](https://github.com/libssh2/libssh2) for SSH transport
- [OpenSSL](https://github.com/openssl/openssl) for cryptography

Xcode resolves the Swift package dependencies in the project.

## Documentation

- [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution workflow
- [SECURITY.md](SECURITY.md) for vulnerability reports
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party notices
- [CLA.md](CLA.md) for the contributor license agreement

## License

Source code in this repository is available under the [GNU General Public License v3.0](LICENSE). Official App Store binaries use the [VVTerm App Store EULA](LICENSE-APPSTORE.md).

Copyright © 2026 Vivy Technologies Co., Limited
