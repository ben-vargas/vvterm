# Security Infrastructure

- Own Keychain access, device identity, and privacy-mode infrastructure here. App lock and biometric user flows belong in `Features/Security`.
- Credentials use opt-in iCloud Keychain sync. Device identity, session resume secrets, and derived caches stay device-only.
- Keep credential values and private key material out of logs and test fixtures.
