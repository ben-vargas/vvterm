# Sync Infrastructure

- Own CloudKit transport and shared sync infrastructure here; feature stores own their product state and merge policy.
- Deduplicate synced records by ID, not by display name.
- Keep local fallback behavior and feature-to-CloudKit mapping explicit at persistence boundaries.
- Read the affected feature's rules when changing sync behavior across owners.
