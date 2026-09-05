---
name: vvterm-device-install
description: Build and install VVTerm on a physical iOS device through CLI when device delivery is requested. Not for simulator-only tests or App Store distribution.
---

# VVTerm Device Installation

Use the repository's build-storage and test rules. Installation does not authorize commits, uploads, or release work.

## Select and Build

1. Check the branch and worktree. Discover the requested device with `xcrun devicectl list devices` and check available Xcode destinations. If several devices match, ask which to use; do not select by a saved personal name or ID.
2. Set `VVTERM_DEVICE_ID` to the verified device ID. Check free disk space. Use the existing project signing configuration; do not change the signing team or credentials to make a build pass.
3. Build the requested source for the physical device. Reuse an existing artifact only if its source and build configuration are verified to match the request.

```sh
xcodebuild -project VVTerm.xcodeproj -scheme VVTerm -configuration Debug -destination "id=$VVTERM_DEVICE_ID" build
```

Use another configuration only when the task requires it. If signing or pairing blocks delivery, report the needed user action; do not disable signing or reset Keychain. Use CLI help for flags supported by the installed Xcode.

## Verify and Install

1. Resolve the built app from `TARGET_BUILD_DIR` and `FULL_PRODUCT_NAME` using `xcodebuild -showBuildSettings` with the same project, scheme, configuration, and destination. Set `VVTERM_APP_PATH` to that exact artifact; do not choose the newest matching app from a directory search.
2. Read `CFBundleIdentifier`, `CFBundleShortVersionString`, and `CFBundleVersion` from its `Info.plist`. Set `VVTERM_BUNDLE_ID` to the verified identifier. Check that it is an iOS-device artifact and verify its signature.
3. Confirm device installation is within the user's request, then install and read back the app's version and build.

```sh
codesign --verify --deep --strict "$VVTERM_APP_PATH"
xcrun devicectl device install app --device "$VVTERM_DEVICE_ID" "$VVTERM_APP_PATH"
xcrun devicectl device info apps --device "$VVTERM_DEVICE_ID" --bundle-id "$VVTERM_BUNDLE_ID"
```

Launch if requested or needed for the requested device test:

```sh
xcrun devicectl device process launch --device "$VVTERM_DEVICE_ID" "$VVTERM_BUNDLE_ID"
```

Do not terminate a running session unless the requested test needs a restart. If device access fails, recheck availability and retry only after a relevant state change. Ask for unlock, trust, or connection when needed.

Report build, installation, and launch results separately. A successful build is not proof of installation; launch is not proof that the feature works. Do not save device identifiers, account details, or machine-specific paths in repository files.
